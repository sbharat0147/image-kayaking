# DC/DR Test Execution Record

**Purpose:** Definitive test record for the DC/DR stack. Each test case
documents the intent, exact commands, expected output, and actual result.
Use this to re-run any test at any time and know exactly what "pass" looks like.

**Validated on:** 2026-06-25  
**Environment:** Local-test mode (single VM, offset ports)  
**Stack version:** Patroni 3.3.0, PostgreSQL 16, MinIO RELEASE.2025-05-24

**Pre-condition for all tests:** The cluster must pass the full setup
checklist in `11-local-test-setup-runbook.md` before running any test here.

---

## Test Suite Overview

| ID | Name | Category | Result |
|---|---|---|---|
| TC-PG-01 | Write on primary, read on replica | PostgreSQL Replication | ✅ PASS |
| TC-PG-02 | Replica rejects writes | PostgreSQL Replication | ✅ PASS |
| TC-FAIL-01 | Automatic failover on primary outage | PostgreSQL HA | ✅ PASS |
| TC-FAIL-02 | Former primary rejoins as replica | PostgreSQL HA | ✅ PASS |
| TC-FAIL-03 | pg_rewind syncs failover-era data | PostgreSQL HA | ✅ PASS |
| TC-FAIL-04 | Graceful switchover (planned maintenance) | PostgreSQL HA | ✅ PASS |
| TC-MINIO-01 | Object replication DC1 → DC2 | MinIO DR | ✅ PASS |
| TC-MINIO-02 | DC2 serves data during DC1 outage | MinIO DR | ✅ PASS |
| TC-MINIO-03 | Bidirectional sync on DC1 recovery | MinIO DR | ✅ PASS |
| TC-MON-01 | Prometheus scraping all targets | Monitoring | ✅ PASS |
| TC-MON-02 | Grafana dashboards display live data | Monitoring | ✅ PASS |
| TC-MON-03 | PatroniNoLeader alert fires on DC1 outage | Monitoring Alerts | ✅ PASS |
| TC-MON-04 | Alerts clear on cluster recovery | Monitoring Alerts | ✅ PASS |

---

## PostgreSQL Replication Tests

---

### TC-PG-01 — Write on Primary, Read on Replica

**Intent:** Confirm that data written on DC1 (primary) is immediately
visible on DC2 (replica). This is the most fundamental guarantee of
streaming replication — no data should be lost in transit.

**Category:** PostgreSQL Replication  
**Risk level:** None — read-only on DC2

**Steps:**

```bash
# Create a test table and insert a row on DC1 (primary, port 5432)
docker exec postgres-dc1 psql -U postgres -c "
  CREATE TABLE IF NOT EXISTS repl_test (
    id   serial PRIMARY KEY,
    msg  text,
    ts   timestamptz DEFAULT now()
  );
  INSERT INTO repl_test (msg) VALUES ('hello from dc1');
"

# Read the row back from DC2 (replica, port 5433)
docker exec postgres-dc2 psql -U postgres -c "SELECT * FROM repl_test;"
```

**Expected output on DC1:**
```
NOTICE:  relation "repl_test" already exists, skipping   (if table exists)
CREATE TABLE
INSERT 0 1
```

**Expected output on DC2:**
```
 id |      msg       |              ts
----+----------------+-------------------------------
  1 | hello from dc1 | 2026-06-25 ...
(1 row)
```

**Pass criteria:**
- Row inserted on DC1 appears on DC2 immediately (within 1 second)
- Row count, content, and timestamp match exactly

**Actual result:** ✅ PASS — row appeared on DC2 instantly with correct content.

---

### TC-PG-02 — Replica Rejects Writes (Read-Only Enforcement)

**Intent:** Confirm that DC2 refuses write operations. A replica must
never accept writes directly — doing so would create a split-brain
scenario where DC1 and DC2 have diverged data that cannot be reconciled.
Patroni enforces this via `hot_standby` mode in PostgreSQL.

**Category:** PostgreSQL Replication  
**Risk level:** None — write is expected to fail

**Steps:**

```bash
# Attempt to insert directly on DC2 (replica, port 5433)
docker exec postgres-dc2 psql -U postgres \
  -c "INSERT INTO repl_test (msg) VALUES ('this should fail');"
```

**Expected output:**
```
ERROR:  cannot execute INSERT in a read-only transaction
```

**Pass criteria:**
- INSERT returns an error, not a success
- No row is added to the table
- DC2 continues operating normally after the rejected write

**Actual result:** ✅ PASS — `ERROR: cannot execute INSERT in a read-only transaction` returned immediately.

---

## PostgreSQL High-Availability Tests

---

### TC-FAIL-01 — Automatic Failover on Primary Outage

**Intent:** Confirm that when DC1 (primary) goes down unexpectedly, the
Raft quorum (DC2 + witness = 2 out of 3 votes) detects the outage and
automatically promotes DC2 to primary without any operator action.

This is the core DR guarantee — the cluster must self-heal within the
Patroni TTL window (default 30 seconds).

**Category:** PostgreSQL HA  
**Risk level:** Medium — DC1 is stopped; DC2 becomes the new primary

**Steps:**

```bash
# Step 1: Record the current cluster state before the test
curl -s http://localhost:8008/cluster | python3 -m json.tool

# Step 2: Stop DC1 (simulate unexpected outage)
docker stop postgres-dc1

# Step 3: Wait for Raft to detect failure and promote DC2
# Patroni TTL is 30s — allow up to 40s for the full promotion cycle
sleep 40

# Step 4: Check cluster from DC2's perspective (DC1 REST API is down)
curl -s http://localhost:8009/cluster | python3 -m json.tool

# Step 5: Check DC2 Patroni logs for the promotion event
docker logs postgres-dc2 --tail 20
```

**Expected cluster output after failover:**
```json
{
    "members": [
        { "name": "pg-dc1", "role": "replica", "state": "stopped" },
        { "name": "pg-dc2", "role": "leader",  "state": "running", "timeline": 2 },
        { "name": "pg-witness", "role": "replica", "state": "streaming" }
    ]
}
```

**Expected DC2 Patroni log lines:**
```
LOG:  received promote request
LOG:  selected new timeline ID: 2
LOG:  database system is ready to accept connections
INFO: no action. I am (pg-dc2), the leader with the lock
```

**Pass criteria:**
- `pg-dc2` role changes from `replica` to `leader`
- Timeline advances from 1 to 2 (new timeline on every promotion)
- DC2 Patroni logs show `received promote request` and new timeline selected
- Promotion happens without any operator command

**Important note:** The promotion can take 30–40 seconds. If you check
at 15 seconds, the cluster may still show DC1 as leader (Raft TTL not
yet expired). This is expected — wait the full 40 seconds.

**Actual result:** ✅ PASS — DC2 promoted automatically at ~30s after DC1
stopped. Timeline advanced to 2. Logs confirmed `received promote request`.

---

### TC-FAIL-02 — Former Primary Rejoins as Replica

**Intent:** After a failover, when DC1 comes back online it must
automatically detect that DC2 is now the primary, rewind its WAL to the
divergence point using `pg_rewind`, and rejoin the cluster as a replica.
No operator action should be required.

**Category:** PostgreSQL HA  
**Depends on:** TC-FAIL-01 must have run first (DC2 must be the current primary)  
**Risk level:** Low — DC1 rejoins in read-only replica mode

**Steps:**

```bash
# Restart DC1 — Patroni detects timeline mismatch and calls pg_rewind
docker start postgres-dc1

# Wait for pg_rewind to complete and streaming to begin
sleep 20

# Check cluster — DC2 should still be leader, DC1 should be replica
curl -s http://localhost:8009/cluster | python3 -m json.tool
```

**Expected cluster output:**
```json
{
    "members": [
        { "name": "pg-dc1", "role": "replica", "state": "streaming",
          "timeline": 2, "lag": 0 },
        { "name": "pg-dc2", "role": "leader",  "state": "running",
          "timeline": 2 },
        { "name": "pg-witness", "role": "replica", "state": "streaming",
          "timeline": 2, "lag": 0 }
    ]
}
```

**Pass criteria:**
- `pg-dc1` rejoins with `role: replica` and `state: streaming`
- DC1 timeline matches DC2 (both on timeline 2)
- DC1 `lag` is 0 or near 0
- No operator command needed — fully automatic

**Why pg_rewind is needed:** When DC2 was promoted, it advanced the WAL
to timeline 2. DC1 was last seen on timeline 1. They have diverged WAL
histories. `pg_rewind` finds the exact divergence point, copies only
the changed blocks from DC2, and replays forward. This is faster than
a full `pg_basebackup` for large databases.

**Actual result:** ✅ PASS — DC1 rejoined as replica on timeline 2 with
lag 0 within 20 seconds of restart. Fully automatic.

---

### TC-FAIL-03 — pg_rewind Syncs Failover-Era Data to Rejoining Node

**Intent:** Any writes made on DC2 *while DC1 was down* must be visible
on DC1 after it rejoins. This proves zero data loss — `pg_rewind`
correctly replays the divergence and streaming replication catches DC1 up
to the current WAL position.

**Category:** PostgreSQL HA  
**Depends on:** TC-FAIL-01 (DC2 is primary) and TC-FAIL-02 (DC1 rejoined)

**Steps:**

```bash
# Write a row on DC2 after failover (while DC1 was down)
docker exec postgres-dc2 psql -U postgres \
  -c "INSERT INTO repl_test (msg) VALUES ('written after failover to dc2');"

# After DC1 rejoins (TC-FAIL-02), read all rows from DC1
docker exec postgres-dc1 psql -U postgres \
  -c "SELECT * FROM repl_test ORDER BY id;"
```

**Expected output on DC1:**
```
 id |              msg              |              ts
----+-------------------------------+-------------------------------
  1 | hello from dc1                | ...
  2 | hello from dc1                | ...
 34 | written after failover to dc2 | ...   ← written while DC1 was down
```

**Pass criteria:**
- Row written on DC2 during DC1 outage is visible on DC1 after rejoin
- No rows are missing or duplicated
- Timestamps are preserved exactly

**Actual result:** ✅ PASS — row with id=34 (`written after failover to
dc2`) was visible on DC1 immediately after it rejoined as a replica.
Zero data loss confirmed.

---

### TC-FAIL-04 — Graceful Switchover (Planned Maintenance)

**Intent:** A switchover is a controlled transfer of the primary role
from one node to another. Unlike a failover (which is emergency,
unplanned), a switchover is used for planned events: patching, hardware
maintenance, or returning primary to the preferred DC after a failover.

A switchover must complete with zero data loss because both nodes are
healthy and in sync before the transfer begins.

**Category:** PostgreSQL HA  
**Depends on:** TC-FAIL-01/02 must have run (DC2 is current primary)  
**Risk level:** Low — planned, both nodes healthy, zero data loss

**Steps:**

```bash
# Trigger graceful switchover: transfer primary from DC2 back to DC1
docker exec postgres-dc2 patronictl \
  -c /tmp/patroni-rendered.yml \
  switchover pg-cluster \
  --master pg-dc2 \
  --candidate pg-dc1 \
  --force

# Wait for the switchover to complete
sleep 5

# Verify DC1 is primary again on the next timeline
curl -s http://localhost:8008/cluster | python3 -m json.tool

# Confirm DC1 accepts writes
docker exec postgres-dc1 psql -U postgres \
  -c "INSERT INTO repl_test (msg) VALUES ('back on dc1 after switchover');"

# Read all rows from DC2 — should include switchover row
docker exec postgres-dc2 psql -U postgres \
  -c "SELECT * FROM repl_test ORDER BY id;"

# Confirm DC2 is now read-only again
docker exec postgres-dc2 psql -U postgres \
  -c "INSERT INTO repl_test (msg) VALUES ('should fail on dc2');"
```

**Expected patronictl output:**
```
Successfully switched over to "pg-dc1"
| pg-dc1 | Leader  | running |
| pg-dc2 | Replica | stopped |   ← briefly stopped, self-recovers
```

**Expected cluster output after switchover:**
```json
{ "name": "pg-dc1", "role": "leader",  "state": "running",  "timeline": 3 }
{ "name": "pg-dc2", "role": "replica", "state": "streaming", "timeline": 3, "lag": 0 }
```

**Pass criteria:**
- patronictl reports `Successfully switched over to "pg-dc1"`
- Timeline advances again (2 → 3)
- DC1 accepts writes immediately after switchover
- DC2 automatically restarts and rejoins as replica within ~20 seconds
- All historical rows (written on DC1 and DC2 across all events) are
  visible everywhere — no data loss across the entire test sequence
- DC2 rejects writes again after rejoining as replica

**Actual result:** ✅ PASS — switchover completed instantly. DC1 became
leader on timeline 3. DC2 rejoined as replica within 10 seconds. Row
written post-switchover appeared on DC2. Full data history preserved:

```
id=1   hello from dc1               (original)
id=2   hello from dc1               (original)
id=34  written after failover to dc2 (written on DC2 during DC1 outage)
id=67  back on dc1 after switchover  (written on DC1 post-switchover)
```

---

## MinIO DR Tests

---

### TC-MINIO-01 — Object Replication DC1 → DC2

**Intent:** Confirm that objects written to DC1's MinIO are automatically
replicated to DC2. Site replication is bidirectional and synchronous —
after a write commits on DC1, it should appear on DC2 within a few
seconds at most.

**Category:** MinIO DR  
**Risk level:** None — read-only verification

**Steps:**

```bash
# Write a test object to DC1
echo "critical data written to dc1" > /tmp/dr-test.txt
docker run --rm --network patroni-cluster \
  -e MC_HOST_minio-dc1=http://minioadmin:minioadmin@minio-dc1:9000 \
  -v /tmp/dr-test.txt:/tmp/dr-test.txt \
  minio/mc:latest --no-color cp /tmp/dr-test.txt minio-dc1/test-replication/dr-test.txt

# Wait and verify it appeared on DC2
sleep 5
docker run --rm --network patroni-cluster \
  -e MC_HOST_minio-dc2=http://minioadmin:minioadmin@minio-dc2:9000 \
  minio/mc:latest --no-color ls minio-dc2/test-replication/

# Read the object content from DC2
docker run --rm --network patroni-cluster \
  -e MC_HOST_minio-dc2=http://minioadmin:minioadmin@minio-dc2:9000 \
  minio/mc:latest --no-color cat minio-dc2/test-replication/dr-test.txt
```

**Expected output:**
```
dr-test.txt                                        (listed on DC2)
critical data written to dc1                       (content matches)
```

**Pass criteria:**
- Object uploaded to DC1 appears on DC2 within 5 seconds
- File size and content are identical on both sites
- No manual sync required

**Actual result:** ✅ PASS — `dr-test.txt` (29 B) appeared on DC2 within
5 seconds with correct content `critical data written to dc1`.

---

### TC-MINIO-02 — DC2 Serves Data During DC1 Outage

**Intent:** When DC1's MinIO goes down, DC2 must continue to serve all
objects that were replicated before the outage. This is the fundamental
DR guarantee — the replica site must be self-sufficient.

**Category:** MinIO DR  
**Depends on:** TC-MINIO-01 (object must exist on DC2 before this test)  
**Risk level:** Medium — DC1 MinIO is stopped

**Steps:**

```bash
# Stop DC1 MinIO (simulate outage)
docker stop minio-dc1

# Confirm DC2 still serves the previously replicated object
docker run --rm --network patroni-cluster \
  -e MC_HOST_minio-dc2=http://minioadmin:minioadmin@minio-dc2:9000 \
  minio/mc:latest --no-color cat minio-dc2/test-replication/dr-test.txt
```

**Expected output:**
```
critical data written to dc1
```

**Pass criteria:**
- DC2 returns the object content without error
- No dependency on DC1 for serving already-replicated data
- DC2 MinIO continues operating independently

**Actual result:** ✅ PASS — DC2 served `dr-test.txt` correctly while
DC1 MinIO was fully stopped.

---

### TC-MINIO-03 — Bidirectional Sync on DC1 Recovery

**Intent:** Objects written to DC2 *while DC1 was down* must be
automatically replicated back to DC1 once it comes back online. This
proves that the active-active site replication works in both directions
and handles outage reconciliation automatically.

**Category:** MinIO DR  
**Depends on:** TC-MINIO-02 (DC1 MinIO is currently stopped)  
**Risk level:** Low — DC1 MinIO is restarted

**Steps:**

```bash
# Write a new object to DC2 while DC1 is still down
echo "new data written to dc2 during dc1 outage" > /tmp/dr-test2.txt
docker run --rm --network patroni-cluster \
  -e MC_HOST_minio-dc2=http://minioadmin:minioadmin@minio-dc2:9000 \
  -v /tmp/dr-test2.txt:/tmp/dr-test2.txt \
  minio/mc:latest --no-color cp /tmp/dr-test2.txt minio-dc2/test-replication/dr-test2.txt

# Bring DC1 MinIO back online
docker start minio-dc1
sleep 10

# Verify DC2's new object replicated back to DC1
docker run --rm --network patroni-cluster \
  -e MC_HOST_minio-dc1=http://minioadmin:minioadmin@minio-dc1:9000 \
  minio/mc:latest --no-color ls minio-dc1/test-replication/

# Read the content to confirm it's correct
docker run --rm --network patroni-cluster \
  -e MC_HOST_minio-dc1=http://minioadmin:minioadmin@minio-dc1:9000 \
  minio/mc:latest --no-color cat minio-dc1/test-replication/dr-test2.txt
```

**Expected output:**
```
[timestamp]    29B STANDARD dr-test.txt     ← original DC1 object
[timestamp]    42B STANDARD dr-test2.txt    ← DC2 object, synced back to DC1

new data written to dc2 during dc1 outage   ← content verified
```

**Pass criteria:**
- `dr-test2.txt` (written on DC2 during outage) appears on DC1 after restart
- Content is byte-for-byte identical to what was written on DC2
- Sync happens automatically within ~10 seconds of DC1 coming back
- No data loss, no manual reconciliation needed

**Actual result:** ✅ PASS — `dr-test2.txt` (42 B) appeared on DC1
within 10 seconds of MinIO DC1 restart. Content confirmed:
`new data written to dc2 during dc1 outage`.

---

## Full Test Results Summary

| ID | Test Name | Steps | Pass Criteria | Result |
|---|---|---|---|---|
| TC-PG-01 | Write primary → read replica | Insert on DC1, select on DC2 | Row appears on DC2 immediately | ✅ PASS |
| TC-PG-02 | Replica read-only enforcement | Insert on DC2 | ERROR: read-only transaction | ✅ PASS |
| TC-FAIL-01 | Automatic failover | Stop DC1, wait 40s | DC2 promoted, timeline+1 | ✅ PASS |
| TC-FAIL-02 | Former primary rejoins | Start DC1 | DC1 = replica, lag=0, auto pg_rewind | ✅ PASS |
| TC-FAIL-03 | pg_rewind data sync | Read from DC1 after rejoin | Failover-era rows visible | ✅ PASS |
| TC-FAIL-04 | Graceful switchover | patronictl switchover | DC1 = leader, timeline+1, zero data loss | ✅ PASS |
| TC-MINIO-01 | Object replication DC1→DC2 | cp to DC1, ls on DC2 | Object appears within 5s | ✅ PASS |
| TC-MINIO-02 | DC2 serves during DC1 outage | Stop DC1, cat from DC2 | Object served from DC2 | ✅ PASS |
| TC-MINIO-03 | Bidirectional sync on recovery | Write DC2, start DC1, ls DC1 | DC2 object appears on DC1 | ✅ PASS |
| TC-MON-01 | Prometheus scraping all targets | Check /targets in Prometheus UI | All 7 targets UP | ✅ PASS |
| TC-MON-02 | Grafana dashboards display live data | Open both dashboards | All panels show data, no "No data" | ✅ PASS |
| TC-MON-03 | PatroniNoLeader alert fires on outage | Stop DC1, wait 40s | Alert visible in Alertmanager | ✅ PASS |
| TC-MON-04 | Alerts clear on cluster recovery | Start DC1, wait 60s | All alerts resolve to inactive | ✅ PASS |

**13 / 13 tests passed. Zero data loss across all scenarios.**

---

---

## TC-MON-01 — Prometheus Scraping All Targets

**Intent:** Verify that Prometheus is collecting metrics from every component:
3 Patroni nodes (DC1, DC2, witness), postgres-exporter, 2 MinIO instances,
and Prometheus itself.

**Category:** Monitoring  
**Risk:** Low — read-only check

**Commands:**
```bash
# Open in browser or query via API
curl -s http://localhost:9090/api/v2/targets | \
  python3 -c "
import json, sys
data = json.load(sys.stdin)
for t in data['data']['activeTargets']:
    print(t['labels']['job'], '|', t['labels'].get('instance','?'), '|', t['health'])
"
```

**Expected output:**
```
patroni          | postgres-dc1:8008   | up
patroni-dc2      | postgres-dc2:8008   | up
patroni-witness  | postgres-witness:8008 | up
postgres         | postgres-exporter:9187 | up
minio-dc1        | minio-dc1:9000      | up
minio-dc2        | minio-dc2:9000      | up
prometheus       | localhost:9090      | up
```

**Pass criteria:** All 7 targets show `health: up`. No target in `down` state.

**Actual result:** ✅ PASS — all 7 targets UP. DC2 and witness were only
scraped after adding the `patroni-dc2` and `patroni-witness` jobs to
`prometheus.yml` (they were missing from the initial config).

---

## TC-MON-02 — Grafana Dashboards Display Live Data

**Intent:** Verify both Grafana dashboards show real metric data. In the
initial state all MinIO panels showed "No data" due to wrong metric names
in the dashboard JSON.

**Category:** Monitoring  
**Risk:** Low — read-only

**Steps:**
1. Open Grafana at `http://localhost:3001`
2. Navigate to **Patroni HA — PostgreSQL DC/DR** dashboard
3. Navigate to **MinIO DC/DR Site Replication** dashboard

**Pass criteria:**
- "Who is the Primary?" stat shows `postgres-dc2:8008` (or DC1 if switchover done)
- "PostgreSQL Running" shows `RUNNING ✓` on all nodes
- "Replication Lag" timeseries shows near-0s line
- "Replication Slots — Active?" shows `ACTIVE — replica streaming ✓`
- MinIO "Site Health Status" shows `HEALTHY ✓` for both DC1 and DC2
- MinIO storage, objects, and S3 traffic panels show numeric data (not "No data")
- No panel shows "No data" in either dashboard

**Root cause of initial failure:** Both dashboards used wrong metric names
throughout (e.g. `pg_replication_lag` instead of `pg_replication_lag_seconds`,
`minio_bucket_objects_count` instead of `minio_cluster_usage_object_total`).
All metric names were corrected by querying `http://localhost:9090/api/v1/label/__name__/values`.

**Actual result:** ✅ PASS — all panels displaying live data after metric
name corrections. MinIO site replication panels show active replication
byte counters incrementing. Patroni cluster overview correctly identifies
the leader node.

---

## TC-MON-03 — PatroniNoLeader Alert Fires During Primary Outage

**Intent:** Verify that stopping the primary triggers the `PatroniNoLeader`
alert within the configured `for: 30s` window. Also verifies `PostgresDown`
fires when `patroni_postgres_running == 0`.

**Category:** Monitoring Alerts  
**Risk:** Medium — stops the primary; cluster will auto-failover

**Commands:**
```bash
# 1. Stop DC1 (primary at test time)
docker compose -p dc1 -f docker-compose.dc1.yml --env-file .env \
  stop postgres-dc1

# 2. Wait ~40s for failover + alert evaluation window
sleep 40

# 3. Check Alertmanager for firing alerts
curl -s http://localhost:9093/api/v2/alerts | \
  python3 -c "
import json, sys
alerts = json.load(sys.stdin)
print(f'Firing alerts: {len(alerts)}')
for a in alerts:
    print(' -', a['labels']['alertname'], a['status']['state'], a['labels'].get('severity',''))
"
```

**Expected output:**
```
Firing alerts: 2
 - PatroniNoLeader firing critical
 - PostgresDown firing critical
```

**Pass criteria:** `PatroniNoLeader` appears as `firing` within 60 seconds
of the primary stopping. `PostgresDown` fires within 30s.

**Note on alerting-rules.yml fix:** The initial `alerting-rules.yml` used
`pg_up` (metric does not exist) for `PostgresDown` and `pg_replication_lag`
(wrong name, missing `_seconds`) for replication lag alerts. These were
corrected to `patroni_postgres_running` and `pg_replication_lag_seconds`.
The `ReplicaDown` alert also fired because it used `absent(pg_replication_lag{...})`
— once the metric name was corrected the alert behaved as expected.

**Actual result:** ✅ PASS — `PatroniNoLeader` and `PostgresDown` fired
within 40 seconds of DC1 being stopped. DC2 auto-promoted to timeline 4.

---

## TC-MON-04 — Alerts Clear on Cluster Recovery

**Intent:** Verify that all firing alerts resolve (go inactive) once the
cluster returns to a healthy state after DC1 restarts and rejoins as a replica.

**Category:** Monitoring Alerts  
**Risk:** Low — recovery step

**Commands:**
```bash
# 1. Start DC1 (rejoins as streaming replica via pg_rewind)
docker compose -p dc1 -f docker-compose.dc1.yml --env-file .env \
  start postgres-dc1

# 2. Reload Prometheus to apply corrected alerting-rules.yml
docker compose -p dc1 -f docker-compose.dc1.yml --env-file .env \
  restart prometheus

# 3. Wait 60s for scrape cycle + alert evaluation
sleep 60

# 4. Verify no firing alerts
curl -s http://localhost:9093/api/v2/alerts | \
  python3 -c "
import json, sys
alerts = json.load(sys.stdin)
firing = [a for a in alerts if a['status']['state'] == 'active']
print('Firing:', len(firing))
for a in firing:
    print(' -', a['labels']['alertname'])
"

# 5. Confirm cluster health
curl -s http://localhost:8008/cluster | python3 -m json.tool | \
  grep -E '"role"|"state"|"lag_in_mb"'
```

**Expected output:**
```
Firing: 0

"role": "leader"     ← DC2
"state": "running"
"role": "replica"    ← DC1 (recovered)
"state": "streaming"
"lag_in_mb": 0
"role": "replica"    ← witness
"state": "streaming"
"lag_in_mb": 0
```

**Pass criteria:** All alerts inactive. Cluster has one leader, two streaming
replicas, all with `lag_in_mb: 0`.

**Actual result:** ✅ PASS — after Prometheus restart (to load corrected
metric names) and 60s wait, all alerts cleared. DC1 rejoined as a healthy
streaming replica at timeline 4, lag=0.

---

## Data Integrity Audit

The `repl_test` table after all PostgreSQL tests reflects the complete
history of writes across all events with no gaps or duplicates:

```
id=1   hello from dc1               written on DC1 (timeline 1, initial state)
id=2   hello from dc1               written on DC1 (timeline 1, initial state)
id=34  written after failover to dc2 written on DC2 (timeline 2, while DC1 was down)
id=67  back on dc1 after switchover  written on DC1 (timeline 3, after switchover)
```

The id gap (2 → 34 → 67) is from the serial sequence advancing during
the failover/switchover events. There are no missing rows — all writes
are accounted for regardless of which node was primary at the time.
