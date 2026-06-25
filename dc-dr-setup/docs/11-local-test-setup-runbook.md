# Local Test Setup Runbook

**Purpose:** Complete step-by-step guide to spin up, verify, and tear down
the full DC/DR stack on a single machine (local-test mode). Follow every step
in order, confirm each checkpoint before moving to the next. This document
captures exactly what was validated on 2026-06-25.

**Time required:** ~5 minutes from cold start to fully verified cluster.

---

## Prerequisites

| Requirement | Check |
|---|---|
| Docker Engine 25+ | `docker --version` |
| Docker Compose v2 | `docker compose version` |
| Python 3 | `python3 --version` |
| curl | `curl --version` |
| Working directory | `dc-dr-setup/` inside the repo |

All commands below assume you are **inside `dc-dr-setup/`**:

```bash
cd path/to/image-kayaking/dc-dr-setup
```

---

## Port Reference

| Service | Host Port | Container Port | Notes |
|---|---|---|---|
| PostgreSQL DC1 | 5432 | 5432 | Primary — read/write |
| PostgreSQL DC2 | 5433 | 5432 | Replica — read-only |
| PostgreSQL Witness | 5434 | 5432 | Quorum voter — not for app traffic |
| Patroni REST API DC1 | 8008 | 8008 | Health / cluster state |
| Patroni REST API DC2 | 8009 | 8008 | |
| Patroni REST API Witness | 8010 | 8008 | |
| MinIO S3 API DC1 | 9000 | 9000 | |
| MinIO Console DC1 | 9001 | 9001 | Web UI |
| MinIO S3 API DC2 | 9002 | 9000 | |
| MinIO Console DC2 | 9003 | 9001 | Web UI |
| Prometheus | 9090 | 9090 | |
| Alertmanager | 9093 | 9093 | |
| Grafana | 3001 | 3000 | Login: admin / admin |
| postgres-exporter | 9187 | 9187 | Prometheus metrics |

---

## Credentials (local-test)

All credentials are in `.env.local`. For local testing the values are:

| Variable | Value |
|---|---|
| `PATRONI_SUPERUSER_PASSWORD` | `testpass123` |
| `PATRONI_REPLICATION_PASSWORD` | `replpass123` |
| `MINIO_ROOT_USER` | `minioadmin` |
| `MINIO_ROOT_PASSWORD` | `minioadmin` |
| `GF_SECURITY_ADMIN_PASSWORD` | `admin` |

pgAdmin / psql connection:
- **DC1 (primary):** host=`localhost`, port=`5432`, user=`postgres`, password=`testpass123`
- **DC2 (replica):** host=`localhost`, port=`5433`, user=`postgres`, password=`testpass123`

---

## Step 1 — Clean Slate (mandatory before every fresh run)

Remove all containers, networks, and volumes from any previous run.
Skipping this step causes timeline mismatches and replication failures.

```bash
docker compose -p dc2 -f docker-compose.dc2-local.yml --env-file .env.local down -v
docker compose -p dc1 -f docker-compose.dc1.yml --env-file .env.local down -v
```

**Expected output:** Each `down -v` prints all containers, volumes, and
networks as `Removed`. If no stack was running, Docker prints nothing —
that is also fine.

---

## Step 2 — Start DC1 Stack (Primary)

DC1 brings up: PostgreSQL+Patroni, MinIO DC1, Prometheus, Alertmanager,
Grafana, postgres-exporter.

```bash
docker compose -p dc1 -f docker-compose.dc1.yml --env-file .env.local up -d
```

**Expected output:**

```
✔ Network dc1_dc-internal       Created
✔ Network patroni-cluster       Created
✔ Volume "dc1_pg_data_dc1"      Created
... (volumes)
✔ Container postgres-dc1        Started
✔ Container minio-dc1           Started
✔ Container prometheus          Started
✔ Container alertmanager        Started
✔ Container grafana             Started
✔ Container postgres-exporter   Started
```

### Checkpoint 2.1 — DC1 is the Patroni leader

Wait ~15 seconds, then:

```bash
curl -s http://localhost:8008/cluster | python3 -m json.tool
```

**Expected:**
```json
{
    "members": [
        {
            "name": "pg-dc1",
            "role": "leader",
            "state": "running",
            "host": "172.30.0.10",
            "port": 5432,
            "timeline": 1
        }
    ],
    "scope": "pg-cluster"
}
```

Only one member visible at this point (DC2 not started yet). `role` must
be `leader` and `timeline` must be `1`.

---

## Step 3 — Start DC2 Stack (Replica + Witness)

DC2 brings up: PostgreSQL+Patroni (replica), PostgreSQL+Patroni (witness),
MinIO DC2.

```bash
docker compose -p dc2 -f docker-compose.dc2-local.yml --env-file .env.local up -d
```

**Expected output:**

```
✔ Network dc2_dc2-internal      Created
✔ Volume "dc2_pg_data_dc2"      Created
... (volumes)
✔ Container postgres-dc2        Started
✔ Container postgres-witness    Started
✔ Container minio-dc2           Started
```

### What happens internally

1. DC2 and witness register with the Raft DCS on DC1.
2. DC1's Patroni creates replication slots `pg_dc2` and `pg_witness`.
3. DC2 and witness run `pg_basebackup` from DC1 (172.30.0.10:5432).
4. After basebackup completes, streaming replication starts.

You may see transient `replication slot does not exist` errors in DC2 logs
for ~10 seconds. **This is normal** — DC2's PostgreSQL starts immediately
after basebackup and retries until DC1 creates the slot. It self-heals.

### Checkpoint 3.1 — All 3 members streaming

Wait ~30 seconds after DC2 starts, then:

```bash
curl -s http://localhost:8008/cluster | python3 -m json.tool
```

**Expected:**
```json
{
    "members": [
        {
            "name": "pg-dc1",
            "role": "leader",
            "state": "running",
            "host": "172.30.0.10",
            "port": 5432,
            "timeline": 1
        },
        {
            "name": "pg-dc2",
            "role": "replica",
            "state": "streaming",
            "host": "172.30.0.20",
            "port": 5432,
            "timeline": 1,
            "lag": 0
        },
        {
            "name": "pg-witness",
            "role": "replica",
            "state": "streaming",
            "host": "172.30.0.30",
            "port": 5432,
            "tags": { "nofailover": true, "noloadbalance": true },
            "lag": 0
        }
    ],
    "scope": "pg-cluster"
}
```

All three must show `state: streaming` (DC2 and witness) or `state: running`
(DC1 leader). `lag` must be `0` or a small number (< 5).

### Checkpoint 3.2 — Replication slots active on DC1

```bash
docker exec postgres-dc1 psql -U postgres \
  -c "SELECT slot_name, active, restart_lsn FROM pg_replication_slots;"
```

**Expected:**
```
 slot_name  | active | restart_lsn
------------+--------+-------------
 pg_dc2     | t      | 0/...
 pg_witness | t      | 0/...
(2 rows)
```

Both slots must show `active = t`. If either shows `f`, wait 10 seconds
and retry — DC2 may still be connecting.

---

## Step 4 — Set Up MinIO Site Replication

Run the one-shot script. It is idempotent — safe to re-run.

```bash
bash scripts/setup-minio-replication.sh .env.local
```

The script:
1. Waits for both MinIO instances to be healthy.
2. Connects both MinIO containers to the `patroni-cluster` Docker network
   (so DC1's MinIO can reach DC2 by container name).
3. Enables bidirectional site replication.
4. Prints the replication status table.

**Expected final output:**
```
SiteReplication enabled for:

Deployment ID    | Site Name  | Endpoint
<uuid>           | minio-dc1  | http://minio-dc1:9000
<uuid>           | minio-dc2  | http://minio-dc2:9000

Done. MinIO site replication is active.
```

### Checkpoint 4.1 — Bucket replication works

```bash
# Create a bucket on DC1
docker run --rm --network patroni-cluster \
  -e MC_HOST_minio-dc1=http://minioadmin:minioadmin@minio-dc1:9000 \
  minio/mc:latest --no-color mb minio-dc1/test-replication

# Wait 5 seconds and confirm it appeared on DC2
sleep 5
docker run --rm --network patroni-cluster \
  -e MC_HOST_minio-dc2=http://minioadmin:minioadmin@minio-dc2:9000 \
  minio/mc:latest --no-color ls minio-dc2
```

**Expected:** The `test-replication/` bucket is listed on DC2.

---

## Step 5 — Verify Monitoring Stack

### Checkpoint 5.1 — Prometheus healthy and all targets UP

```bash
curl -s http://localhost:9090/-/healthy && echo "Prometheus OK"

curl -s http://localhost:9090/api/v1/targets | python3 -c "
import json, sys
data = json.load(sys.stdin)
for t in data['data']['activeTargets']:
    print(t['labels'].get('job','?'), '-', t['health'], '-', t['scrapeUrl'])
"
```

**Expected:**
```
Prometheus OK
minio-dc1   - up - http://minio-dc1:9000/minio/v2/metrics/cluster
patroni     - up - http://postgres-dc1:8008/metrics
postgres    - up - http://postgres-exporter:9187/metrics
prometheus  - up - http://localhost:9090/metrics
```

All four targets must show `up`.

### Checkpoint 5.2 — Grafana dashboards accessible

Open **http://localhost:3001** in your browser.
Login: `admin` / `admin`

Navigate to **Dashboards** and verify both dashboards are present:
- **Patroni HA — PostgreSQL DC/DR**
- **MinIO DC/DR Replication**

On the Patroni dashboard the top stat strip should show:
- Cluster Leader: `PRIMARY ✓` (green)
- PostgreSQL Status: `UP ✓` (green)
- WAL Timeline: `1`
- Replication Lag: `0s` (green)
- Cluster Locked: `LOCKED ✓` (green)

---

## Step 6 — End-to-End PostgreSQL Replication Test

```bash
# Create table and insert a row on DC1 (primary, port 5432)
docker exec postgres-dc1 psql -U postgres -c "
  CREATE TABLE IF NOT EXISTS repl_test (
    id   serial PRIMARY KEY,
    msg  text,
    ts   timestamptz DEFAULT now()
  );
  INSERT INTO repl_test (msg) VALUES ('hello from dc1');
"

# Read it back from DC2 (replica, port 5433)
docker exec postgres-dc2 psql -U postgres -c "SELECT * FROM repl_test;"
```

**Expected:** The row `hello from dc1` appears on DC2.

```bash
# Confirm DC2 is read-only (writes must fail)
docker exec postgres-dc2 psql -U postgres \
  -c "INSERT INTO repl_test (msg) VALUES ('this should fail');"
```

**Expected error:**
```
ERROR:  cannot execute INSERT in a read-only transaction
```

---

## Step 7 — Failover Test (Optional but recommended)

Simulate DC1 failure and verify DC2 is promoted automatically.

```bash
# 1. Record current primary
curl -s http://localhost:8008/leader

# 2. Stop DC1 (simulate outage)
docker stop postgres-dc1

# 3. Wait for Raft quorum to elect DC2 as new primary (~10-15 seconds)
sleep 15

# 4. Check cluster from DC2's perspective
curl -s http://localhost:8009/cluster | python3 -m json.tool
# Expected: pg-dc2 is now "leader"

# 5. Confirm DC2 is now accepting writes
docker exec postgres-dc2 psql -U postgres \
  -c "INSERT INTO repl_test (msg) VALUES ('written after failover to dc2');"

# 6. Restart DC1 — it should rejoin as a replica automatically
docker start postgres-dc1
sleep 20

# 7. Verify DC1 is back as a replica
curl -s http://localhost:8009/cluster | python3 -m json.tool
# Expected: pg-dc1 role=replica, state=streaming, lag=0
```

---

## Step 8 — Switchover Test (Graceful, no data loss)

Return primary back to DC1 gracefully (planned maintenance scenario).

```bash
# Patronictl switchover — only works when both nodes are healthy
docker exec postgres-dc2 patronictl \
  -c /tmp/patroni-rendered.yml \
  switchover pg-cluster \
  --master pg-dc2 \
  --candidate pg-dc1 \
  --force

# Verify DC1 is primary again
sleep 5
curl -s http://localhost:8008/cluster | python3 -m json.tool
```

---

## Tear Down

### Keep data (stop containers but preserve volumes)

```bash
docker compose -p dc2 -f docker-compose.dc2-local.yml --env-file .env.local down
docker compose -p dc1 -f docker-compose.dc1.yml --env-file .env.local down
```

### Full clean (remove everything including data volumes)

**Always use this before a fresh test run to avoid stale volume errors.**

```bash
docker compose -p dc2 -f docker-compose.dc2-local.yml --env-file .env.local down -v
docker compose -p dc1 -f docker-compose.dc1.yml --env-file .env.local down -v
```

---

## Full Setup Checklist

Use this as a go/no-go gate before any further testing.

```
[ ] Step 1: All containers and volumes from previous run removed
[ ] Step 2: DC1 stack started — 6 containers running
[ ] Step 2.1: curl http://localhost:8008/cluster shows pg-dc1 as leader, timeline=1
[ ] Step 3: DC2 stack started — 3 containers running
[ ] Step 3.1: All 3 members show state=streaming, lag=0
[ ] Step 3.2: pg_dc2 and pg_witness slots both show active=t
[ ] Step 4: setup-minio-replication.sh completes with "Site replication is active"
[ ] Step 4.1: test-replication bucket appears on DC2 within 5 seconds
[ ] Step 5.1: All 4 Prometheus targets show "up"
[ ] Step 5.2: Both Grafana dashboards load with green stat panels
[ ] Step 6: repl_test row written on DC1 is readable on DC2
[ ] Step 6: INSERT on DC2 returns "cannot execute INSERT in a read-only transaction"
```

All boxes checked = cluster is healthy and ready for DR scenario testing.

---

## Common Issues and Fixes

| Symptom | Cause | Fix |
|---|---|---|
| DC2 stuck at `creating replica` | pg_basebackup in progress | Wait 30-60s and recheck |
| `replication slot "pg_dc2" does not exist` (then self-heals) | Race: DC2 starts before DC1 creates the slot | Normal — Patroni retries and self-heals in ~10s |
| `active = f` on replication slot | DC2 not streaming (timeline mismatch from stale volume) | Run `down -v` then start fresh |
| Timeline mismatch (DC1=7, DC2=4) | Stale DC2 volume from a previous run with more failovers | Run `down -v` then start fresh |
| `pg_basebackup: Connection refused at 127.0.0.1:5432` | `connect_address` set to `127.0.0.1` — inside DC2 container that resolves to DC2 itself | Fixed: `PATRONI_CONNECT_IP` set to Docker network IP (172.30.0.10/20/30) |
| MinIO replication: `connection refused` | mc ran on wrong network — DC1 MinIO can't reach DC2 | Fixed: `setup-minio-replication.sh` connects both containers to `patroni-cluster` network |
| Grafana port 3000 conflict | Another process using port 3000 | Fixed: Grafana mapped to host port 3001 |
| `docker compose` shows `version` warning | Obsolete top-level `version:` attribute | Fixed: removed from all compose files |
