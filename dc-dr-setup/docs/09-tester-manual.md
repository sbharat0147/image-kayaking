# Tester Manual — DC/DR Validation

**Audience:** QA engineer or SRE validating the DC/DR cluster behaviour.

**Structure:**
- **Phase 1** — Internet-connected machine (developer laptop or CI server).
  Full stack runs locally in a single-VM local-test mode. Fast iteration,
  easy to reset.
- **Phase 2** — Airgap environment. Two VMs, no internet. Validates the
  real production topology.

Run Phase 1 fully before starting Phase 2. All test IDs are unique so
failures can be referenced in bug reports.

---

## Environment Setup

### Phase 1 — Local Test (Internet Machine)

**Prerequisites:**

```bash
docker compose version   # must be v2+
python3 --version        # 3.8+
curl --version
psql --version           # any postgresql-client package
```

**Start the stack:**

```bash
cd dc-dr-setup/

# Copy and fill in the .env (local-test values shown)
cp .env.example .env
cat > .env <<'EOF'
DC1_IP=127.0.0.1
DC2_IP=127.0.0.1
PATRONI_SUPERUSER_PASSWORD=testpass123
PATRONI_REPLICATION_PASSWORD=replpass123
MINIO_ROOT_USER=minioadmin
MINIO_ROOT_PASSWORD=miniopass123
EOF

# Start DC1 (primary + monitoring)
docker compose -p dc1 -f docker-compose.dc1.yml --env-file .env up -d

# Wait for Patroni to bootstrap (~30s)
sleep 30

# Start DC2 (replica + witness, same VM offset ports)
docker compose -p dc2 -f docker-compose.dc2-local.yml --env-file .env up -d

# Wait for streaming to start (~60s)
sleep 60
```

**Port map for local-test:**

| Service | DC1 port | DC2 port |
|---|---|---|
| PostgreSQL | 5432 | 5433 |
| Patroni REST | 8008 | 8009 |
| MinIO S3 | 9000 | 9002 |
| MinIO Console | 9001 | 9003 |
| Prometheus | 9090 | — |
| Grafana | 3000 | — |
| Alertmanager | 9093 | — |
| MCP Server | 8080 | — |

### Phase 2 — Airgap Two-VM

Follow [08-airgap-developer-setup.md](08-airgap-developer-setup.md) to bring
up both VMs before running any tests below.

Replace `localhost` with `<DC1_IP>` or `<DC2_IP>` as indicated.
Ports are the same on both VMs (5432, 8008, 9000, etc.).

---

## Pre-Test Health Gate

**All of the following must pass before running any test scenario.**
If any check fails, stop and fix the cluster first.

```bash
# PG-GATE-1: DC1 is Patroni leader
curl -s http://localhost:8008/leader
# PASS if output is: "pg-dc1"

# PG-GATE-2: All 3 members present
curl -s http://localhost:8008/cluster | python3 -c "
import sys, json
d = json.load(sys.stdin)
members = d['members']
print('Members:', len(members))
for m in members:
    print(f'  {m[\"name\"]:15s} role={m[\"role\"]:8s} state={m[\"state\"]}')
assert len(members) == 3, 'FAIL: expected 3 members'
print('PASS')
"

# PG-GATE-3: Replication lag near zero
curl -s http://localhost:8008/cluster | python3 -c "
import sys, json
d = json.load(sys.stdin)
for m in d['members']:
    lag = m.get('lag', 'n/a')
    role = m.get('role', '')
    if role in ('Replica', 'replica') and str(lag) not in ('0', '', 'n/a'):
        print(f'WARN: {m[\"name\"]} lag={lag}')
    else:
        print(f'OK  : {m[\"name\"]} lag={lag}')
"

# MINIO-GATE-1: Both MinIO instances healthy
curl -sf http://localhost:9000/minio/health/live && echo "DC1 MinIO: PASS"
# Phase 1 (local-test):
curl -sf http://localhost:9002/minio/health/live && echo "DC2 MinIO: PASS"
# Phase 2 (two-VM) — run from DC2:
# curl -sf http://<DC2_IP>:9000/minio/health/live && echo "DC2 MinIO: PASS"

# MON-GATE-1: Prometheus has active targets
curl -s http://localhost:9090/api/v1/targets | python3 -c "
import sys, json
targets = json.load(sys.stdin)['data']['activeTargets']
for t in targets:
    status = '✓' if t['health'] == 'up' else '✗ FAIL'
    print(f'{status} {t[\"labels\"][\"job\"]}')"
```

---

## Test Suite

---

### Block 1 — PostgreSQL Replication

#### TC-PG-01: Write on primary, read on replica

```bash
# Write on DC1
psql -h localhost -p 5432 -U postgres -c "
  CREATE TABLE IF NOT EXISTS tc_pg_01 (id serial PRIMARY KEY, val text, ts timestamptz DEFAULT now());
  INSERT INTO tc_pg_01 (val) VALUES ('replication-check-$(date +%s)');
"

sleep 2

# Read from DC2 replica
# Phase 1: port 5433  |  Phase 2: psql -h <DC2_IP> -p 5432
psql -h localhost -p 5433 -U postgres -c "SELECT * FROM tc_pg_01 ORDER BY id DESC LIMIT 1;"
```

**PASS criteria:** The row inserted on DC1 is visible on DC2.

---

#### TC-PG-02: Replica is read-only

```bash
psql -h localhost -p 5433 -U postgres -c "
  INSERT INTO tc_pg_01 (val) VALUES ('should-fail');
"
```

**PASS criteria:** `ERROR: cannot execute INSERT in a read-only transaction`

---

#### TC-PG-03: Lag stays low under write load

```bash
# Generate 10 000 rows on DC1
psql -h localhost -p 5432 -U postgres -c "
  INSERT INTO tc_pg_01 (val)
  SELECT 'load-test-' || i FROM generate_series(1, 10000) i;
"

# Immediately check lag
curl -s http://localhost:8008/cluster | python3 -c "
import sys, json
for m in json.load(sys.stdin)['members']:
    print(m['name'], 'lag=', m.get('lag','n/a'))
"
```

**PASS criteria:** Lag returns to 0 within 10 seconds of insert completing.

---

### Block 2 — Patroni Automatic Failover

> **Note:** These tests are destructive. Each one ends with a restore step.
> Confirm the cluster is back to normal (health gate) before running the next test.

#### TC-FAIL-01: DC1 crash → automatic failover to DC2

```bash
# Record current leader
curl -s http://localhost:8008/leader

# Simulate DC1 crash
docker stop postgres-dc1

# Poll until DC2 becomes leader (should happen within 30s)
for i in $(seq 1 20); do
  LEADER=$(curl -s http://localhost:8009/leader 2>/dev/null)
  echo "[$i] leader = $LEADER"
  [ "$LEADER" = '"pg-dc2"' ] && echo "PASS: DC2 promoted" && break
  sleep 3
done
```

**PASS criteria:** `pg-dc2` becomes leader within 30 seconds of `docker stop`.

**Verify data is still accessible:**

```bash
psql -h localhost -p 5433 -U postgres -c "SELECT COUNT(*) FROM tc_pg_01;"
# PASS: returns a count (no data loss)
```

**Restore DC1 as replica:**

```bash
docker start postgres-dc1

# Wait for DC1 to rejoin using pg_rewind
sleep 30
curl -s http://localhost:8008/cluster | python3 -c "
import sys, json
for m in json.load(sys.stdin)['members']:
    print(m['name'], m['role'], 'lag=', m.get('lag','n/a'))
"
# PASS: pg-dc1 shows role=Replica, lag=0
```

---

#### TC-FAIL-02: Witness crash — cluster remains operational

```bash
# Stop witness
docker stop postgres-witness

sleep 5

# Cluster should still have quorum (DC1 + DC2 = 2/3)
curl -s http://localhost:8008/leader
# PASS: DC1 still shows as leader

# Write should still succeed
psql -h localhost -p 5432 -U postgres -c "
  INSERT INTO tc_pg_01 (val) VALUES ('witness-down-write');
"
# PASS: insert succeeds

# Restore witness
docker start postgres-witness
sleep 20
curl -s http://localhost:8008/cluster
# PASS: all 3 members back
```

---

#### TC-FAIL-03: Network partition simulation (DC2 unreachable)

Simulates DC2 losing connectivity. DC1 and witness maintain quorum and keep serving.

```bash
# Phase 1 (local-test): pause DC2 container
docker pause postgres-dc2

sleep 15

# DC1 should still be leader (witness provides quorum)
curl -s http://localhost:8008/leader
# PASS: "pg-dc1"

# Write should succeed
psql -h localhost -p 5432 -U postgres -c "
  INSERT INTO tc_pg_01 (val) VALUES ('dc2-partitioned');
"
# PASS: insert succeeds

# Restore DC2
docker unpause postgres-dc2
sleep 30

# DC2 should resync the missed writes
psql -h localhost -p 5433 -U postgres -c "
  SELECT val FROM tc_pg_01 WHERE val='dc2-partitioned';
"
# PASS: row is present on DC2
```

---

#### TC-FAIL-04: DC1 rejoin after failover (pg_rewind)

Builds on TC-FAIL-01 — verify DC1 resyncs cleanly after a failover.

```bash
# 1. Confirm DC2 is now leader (from TC-FAIL-01 restore step)
curl -s http://localhost:8009/leader
# Expected: "pg-dc2"

# 2. Write on new primary (DC2)
psql -h localhost -p 5433 -U postgres -c "
  INSERT INTO tc_pg_01 (val) VALUES ('written-on-dc2-after-failover');
"

# 3. Stop DC2, re-promote DC1 (manual switchback)
curl -s -X POST http://localhost:8008/switchover \
  -H "Content-Type: application/json" \
  -d '{"leader":"pg-dc2","candidate":"pg-dc1"}'

sleep 30

# 4. DC1 is leader again
curl -s http://localhost:8008/leader
# PASS: "pg-dc1"

# 5. Row written on DC2 is visible on DC1
psql -h localhost -p 5432 -U postgres -c "
  SELECT val FROM tc_pg_01 WHERE val='written-on-dc2-after-failover';
"
# PASS: 1 row returned — no data loss across both directions
```

---

### Block 3 — MinIO DC/DR Replication

#### TC-MINIO-01: Bucket creation replicates

```bash
MC="docker run --rm --network host minio/mc:RELEASE.2024-11-17T19-35-25Z"

$MC alias set dc1 http://localhost:9000 minioadmin miniopass123
$MC alias set dc2 http://localhost:9002 minioadmin miniopass123   # Phase 1
# Phase 2: $MC alias set dc2 http://<DC2_IP>:9000 ...

$MC mb dc1/tc-minio-01

sleep 3

$MC ls dc2/ | grep tc-minio-01
# PASS: bucket visible on DC2
```

---

#### TC-MINIO-02: Object replication DC1 → DC2

```bash
MC="docker run --rm -i --network host minio/mc:RELEASE.2024-11-17T19-35-25Z"

echo -n "hello-from-dc1-$(date +%s)" | \
  $MC pipe dc1/tc-minio-01/test-object.txt

sleep 3

$MC cat dc2/tc-minio-01/test-object.txt
# PASS: content visible on DC2
```

---

#### TC-MINIO-03: Object replication DC2 → DC1 (bidirectional)

```bash
MC="docker run --rm -i --network host minio/mc:RELEASE.2024-11-17T19-35-25Z"

echo -n "hello-from-dc2-$(date +%s)" | \
  $MC pipe dc2/tc-minio-01/dc2-object.txt

sleep 3

$MC cat dc1/tc-minio-01/dc2-object.txt
# PASS: content visible on DC1
```

---

#### TC-MINIO-04: Replication recovery after DC2 outage

```bash
MC="docker run --rm -i --network host minio/mc:RELEASE.2024-11-17T19-35-25Z"

# Pause DC2 MinIO
docker stop minio-dc2   # Phase 1: minio-dc2  |  Phase 2: run on DC2 host

# Write to DC1 while DC2 is down
echo -n "offline-write-$(date +%s)" | \
  $MC pipe dc1/tc-minio-01/offline-write.txt

# Restart DC2 MinIO
docker start minio-dc2
sleep 15

# Verify object appears on DC2 (MinIO queues and retries)
$MC cat dc2/tc-minio-01/offline-write.txt
# PASS: content present — MinIO healed the gap automatically
```

---

#### TC-MINIO-05: Large object replication

```bash
MC="docker run --rm --network host \
  -v /tmp:/tmp \
  minio/mc:RELEASE.2024-11-17T19-35-25Z"

# Create a 100 MB test file
dd if=/dev/urandom of=/tmp/large-test.bin bs=1M count=100 2>/dev/null

$MC cp /tmp/large-test.bin dc1/tc-minio-01/large-test.bin

# Wait for replication (allow 30s for 100 MB over local network)
sleep 30

# Verify size on DC2
$MC stat dc2/tc-minio-01/large-test.bin | grep Size
# PASS: Size matches (104857600 bytes)
```

---

### Block 4 — Monitoring Stack

#### TC-MON-01: Prometheus scraping all targets

```bash
curl -s http://localhost:9090/api/v1/targets | python3 -c "
import sys, json
data = json.load(sys.stdin)['data']['activeTargets']
failed = [t for t in data if t['health'] != 'up']
if failed:
    print('FAIL: unhealthy targets:')
    for t in failed:
        print(' ', t['labels']['job'], t['lastError'])
else:
    print(f'PASS: all {len(data)} targets UP')
"
```

---

#### TC-MON-02: Grafana dashboards load with data

1. Open `http://localhost:3000` — login `admin / admin`
2. Navigate to **Dashboards → Patroni HA**
   - **PASS:** "Cluster Leader" panel shows green `PRIMARY` chip for `dc=dc1`
   - **PASS:** "Replication Lag" graph shows a line near 0
3. Navigate to **Dashboards → MinIO DC/DR**
   - **PASS:** "MinIO Health Status" shows `HEALTHY` for dc1
   - **PASS:** "Replication Pending Objects" shows 0 or near-0

---

#### TC-MON-03: Alert fires when replica lag is high

```bash
# Pause DC2 replication network to induce lag (Phase 1)
docker pause postgres-dc2

# Wait 3 minutes for ReplicaLagHigh alert to fire
sleep 180

# Check Alertmanager for fired alerts
curl -s http://localhost:9093/api/v2/alerts | python3 -c "
import sys, json
alerts = json.load(sys.stdin)
for a in alerts:
    print(a['labels']['alertname'], '|', a['status']['state'])
"
# PASS: ReplicaLagHigh or ReplicaDown appears with state=active

# Restore
docker unpause postgres-dc2
```

---

#### TC-MON-04: PatroniNoLeader alert fires during failover

```bash
# Stop DC1 (no leader for up to 30s during election)
docker stop postgres-dc1

# Poll alertmanager for up to 60s
for i in $(seq 1 12); do
  ALERTS=$(curl -s http://localhost:9093/api/v2/alerts | \
    python3 -c "import sys,json; [print(a['labels']['alertname']) for a in json.load(sys.stdin)]" 2>/dev/null)
  echo "[$i] alerts: $ALERTS"
  echo "$ALERTS" | grep -q PatroniNoLeader && echo "PASS: PatroniNoLeader fired" && break
  sleep 5
done

# Restore
docker start postgres-dc1
sleep 30
```

---

### Block 5 — MCP Server

#### TC-MCP-01: Health check returns registered tools

```bash
API_KEY="changeme-mcp-api-key"

curl -s -H "X-API-Key: $API_KEY" http://localhost:8080/health | python3 -c "
import sys, json
d = json.load(sys.stdin)
print('Status:', d['status'])
print('Tools registered:', d['tools_registered'])
assert d['status'] == 'ok', 'FAIL: status not ok'
assert d['tools_registered'] > 0, 'FAIL: no tools registered'
print('PASS')
"
```

---

#### TC-MCP-02: Tool list returns expected tools

```bash
API_KEY="changeme-mcp-api-key"

curl -s -H "X-API-Key: $API_KEY" http://localhost:8080/tools | python3 -c "
import sys, json
tools = json.load(sys.stdin)
names = [t['name'] for t in tools]
print('Tools:', names)
expected = ['create_note', 'list_notes', 'search', 'semantic_search']
missing = [t for t in expected if t not in names]
if missing:
    print('FAIL: missing tools:', missing)
else:
    print('PASS: all expected tools registered')
"
```

---

#### TC-MCP-03: Direct tool execution

```bash
API_KEY="changeme-mcp-api-key"

# Create a note
RESULT=$(curl -s -X POST http://localhost:8080/tools/execute \
  -H "X-API-Key: $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"tool": "create_note", "args": {"title": "TC-MCP-03", "body": "Test note from tester manual"}}')
echo "$RESULT" | python3 -m json.tool
# PASS: result contains note id or success indicator

# List notes — should contain the one we just created
curl -s -X POST http://localhost:8080/tools/execute \
  -H "X-API-Key: $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"tool": "list_notes", "args": {}}' | python3 -m json.tool
# PASS: TC-MCP-03 note appears in list
```

---

#### TC-MCP-04: Semantic search via embedding

```bash
API_KEY="changeme-mcp-api-key"

curl -s -X POST http://localhost:8080/tools/execute \
  -H "X-API-Key: $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"tool": "search", "args": {"query": "python programming"}}' | python3 -m json.tool
# PASS: returns results, no 500 error
```

---

#### TC-MCP-05: Agent ReAct loop — end to end

```bash
API_KEY="changeme-mcp-api-key"

curl -s -X POST http://localhost:8080/agent/run \
  -H "X-API-Key: $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"query": "Search for documents about databases and summarise what you find"}' \
  | python3 -c "
import sys, json
d = json.load(sys.stdin)
print('Answer:', d.get('answer','')[:200])
print('Tools used:', d.get('tools_used', []))
assert d.get('answer'), 'FAIL: no answer in response'
assert d.get('tools_used'), 'FAIL: agent used no tools'
print('PASS')
"
```

---

## Phase 2 — Airgap-Specific Tests

Run the full Phase 1 test suite above on the two-VM airgap environment.
In addition, run these airgap-specific checks.

#### TC-AIR-01: No outbound internet calls during operation

On the DC1 VM, capture traffic for 60 seconds and verify no external connections:

```bash
# Requires tcpdump
sudo tcpdump -i any -nn \
  'not net 192.168.0.0/16 and not net 172.0.0.0/8 and not net 10.0.0.0/8 and not net 127.0.0.0/8' \
  -c 100 -w /tmp/external-traffic.pcap &
TCPDUMP_PID=$!

# Run normal operations for 60s
sleep 60

kill $TCPDUMP_PID 2>/dev/null
PKTS=$(tcpdump -r /tmp/external-traffic.pcap 2>/dev/null | wc -l)
echo "External packets captured: $PKTS"
# PASS: 0 or near-0 packets
```

---

#### TC-AIR-02: Cluster restart survives without internet

```bash
# Stop everything
docker compose -p dc1 -f docker-compose.dc1.yml down
docker compose -p dc2 -f docker-compose.dc2.yml down

# Restart from images (no pulls, no internet)
docker compose -p dc1 -f docker-compose.dc1.yml --env-file .env up -d
sleep 30
docker compose -p dc2 -f docker-compose.dc2.yml --env-file .env up -d
sleep 60

# All health checks must pass
curl -s http://localhost:8008/leader
curl -s http://localhost:9000/minio/health/live && echo "MinIO OK"
# PASS: cluster comes back cleanly from local images + volumes
```

---

#### TC-AIR-03: MCP Server starts without HF network calls

```bash
docker compose -f mcp-server/docker-compose.yml down
docker compose -f mcp-server/docker-compose.yml up -d

docker compose -f mcp-server/docker-compose.yml logs mcp-server | grep -i huggingface
# PASS: no huggingface.co references in logs

docker compose -f mcp-server/docker-compose.yml logs mcp-server | grep -i "application startup complete"
# PASS: server starts successfully
```

---

## Test Results Template

Copy this table into your test report and fill in results.

```
Test ID        | Description                          | Phase | Status | Notes
---------------|--------------------------------------|-------|--------|-------
TC-PG-01       | Write DC1, read DC2                  | 1 & 2 |        |
TC-PG-02       | Replica read-only                    | 1 & 2 |        |
TC-PG-03       | Lag under write load                 | 1 & 2 |        |
TC-FAIL-01     | DC1 crash → DC2 failover             | 1 & 2 |        |
TC-FAIL-02     | Witness crash, cluster operational   | 1 & 2 |        |
TC-FAIL-03     | Network partition DC2                | 1 & 2 |        |
TC-FAIL-04     | DC1 rejoin after failover (pg_rewind)| 1 & 2 |        |
TC-MINIO-01    | Bucket creation replicates           | 1 & 2 |        |
TC-MINIO-02    | Object replication DC1→DC2           | 1 & 2 |        |
TC-MINIO-03    | Object replication DC2→DC1           | 1 & 2 |        |
TC-MINIO-04    | Replication recovery after outage    | 1 & 2 |        |
TC-MINIO-05    | Large object replication             | 1 & 2 |        |
TC-MON-01      | Prometheus all targets UP            | 1 & 2 |        |
TC-MON-02      | Grafana dashboards show data         | 1 & 2 |        |
TC-MON-03      | ReplicaLagHigh alert fires           | 1 & 2 |        |
TC-MON-04      | PatroniNoLeader alert fires          | 1 & 2 |        |
TC-MCP-01      | Health check returns tools           | 1 & 2 |        |
TC-MCP-02      | Tool list complete                   | 1 & 2 |        |
TC-MCP-03      | Direct tool execution                | 1 & 2 |        |
TC-MCP-04      | Semantic search                      | 1 & 2 |        |
TC-MCP-05      | Agent ReAct end-to-end               | 1 & 2 |        |
TC-AIR-01      | No outbound internet traffic         | 2     |        |
TC-AIR-02      | Cluster restarts from local images   | 2     |        |
TC-AIR-03      | MCP Server starts offline            | 2     |        |
```

Status values: `PASS` / `FAIL` / `SKIP` / `BLOCKED`

---

## Common Test Failures and Fixes

| Test | Failure | Likely cause | Fix |
|---|---|---|---|
| TC-PG-01 | Row not visible on DC2 | Streaming not started | Wait 60s after DC2 starts; check `docker logs postgres-dc2` |
| TC-FAIL-01 | DC2 not promoted after 30s | Raft quorum issue | Verify witness is running; check static IPs in patroni config |
| TC-FAIL-04 | DC1 rejoins but diverged | pg_rewind not installed in image | Check Patroni logs for `use_pg_rewind` |
| TC-MINIO-02 | Object not on DC2 | Site replication not wired | Run `mc admin replicate add dc1 dc2` |
| TC-MINIO-04 | Object missing after DC2 restart | MinIO queue not drained | Increase sleep to 30s; check `mc admin replicate info dc1` |
| TC-MON-01 | postgres_exporter target DOWN | Wrong password in `.env` | Verify `PATRONI_SUPERUSER_PASSWORD` matches running PG |
| TC-MCP-05 | Agent returns no answer | Ollama not reachable | Check `OLLAMA_URL` in `.env`; verify `OLLAMA_HOST=0.0.0.0` |
| TC-AIR-01 | External packets found | Proxy env vars leaking | Set `HTTP_PROXY=` and `HTTPS_PROXY=` in service environment |
| TC-AIR-03 | MCP Server logs HF error | Embedding model not in image | Re-run `download-model.sh` and rebuild image on build machine |
