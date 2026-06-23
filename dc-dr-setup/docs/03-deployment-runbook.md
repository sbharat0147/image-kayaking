# Deployment Runbook — First-Time Setup

Follow these steps in exact order. Each step has a verification check.
Do not proceed to the next step until the check passes.

---

## Mode Selection

| Mode | When to use | Compose files |
|---|---|---|
| **Local test** | Single VM, offset ports | `docker-compose.dc1.yml` + `docker-compose.dc2-local.yml` |
| **Two-VM production** | Separate DC1 and DC2 hosts | `docker-compose.dc1.yml` on DC1, `docker-compose.dc2.yml` on DC2 |

---

## Phase 1 — DC1 Stack (Primary)

Run on the **DC1 VM**.

```bash
cd /opt/dc-dr/dc-dr-setup   # or wherever you extracted the bundle

# Start DC1 (Patroni + MinIO + monitoring)
docker compose -p dc1 \
  -f docker-compose.dc1.yml \
  --env-file .env \
  up -d
```

### Check 1.1 — Patroni bootstrapped

```bash
# Wait ~30 seconds for PostgreSQL to initialize
sleep 30

curl -s http://localhost:8008/leader
# Expected: "pg-dc1"

curl -s http://localhost:8008/cluster | python3 -m json.tool
# Expected: members array with pg-dc1 as leader, role=running
```

### Check 1.2 — PostgreSQL accepting connections

```bash
psql -h localhost -p 5432 -U postgres -c "SELECT version();"
# Expected: PostgreSQL 16.x ...
```

### Check 1.3 — MinIO healthy

```bash
curl -s http://localhost:9000/minio/health/live && echo "MinIO DC1: OK"
```

---

## Phase 2 — DC2 Stack (Replica + Witness)

### Local-test mode (same VM as DC1):

```bash
docker compose -p dc2 \
  -f docker-compose.dc2-local.yml \
  --env-file .env \
  up -d
```

### Two-VM production mode (run on DC2 VM):

```bash
docker compose -p dc2 \
  -f docker-compose.dc2.yml \
  --env-file .env \
  up -d
```

> **Important**: The `patroni-cluster` Docker network is created by DC1's compose file.
> In two-VM mode, Raft peers communicate over the physical network using IPs —
> update `patroni.dc2.yml` and `patroni.witness.yml` to use actual host IPs
> instead of the 172.30.0.x addresses (which only work in local-test mode).

### Check 2.1 — DC2 replica streaming

```bash
# ~60s after DC2 starts, pg_basebackup completes and streaming begins
sleep 60

# Query from DC1 Patroni
curl -s http://localhost:8008/cluster | python3 -m json.tool
# Expected: pg-dc2 with role=replica, lag=0 (or small number)
# Expected: pg-witness with role=replica, tags.nofailover=true
```

### Check 2.2 — Replication working end-to-end

```bash
# Write on DC1 primary (port 5432)
psql -h localhost -p 5432 -U postgres \
  -c "CREATE TABLE repl_test (id serial, ts timestamptz default now());"
psql -h localhost -p 5432 -U postgres \
  -c "INSERT INTO repl_test DEFAULT VALUES;"

# Read from DC2 replica (port 5433 local-test, 5432 two-VM)
psql -h localhost -p 5433 -U postgres \
  -c "SELECT * FROM repl_test;"
# Expected: 1 row returned

# Confirm DC2 is read-only
psql -h localhost -p 5433 -U postgres \
  -c "INSERT INTO repl_test DEFAULT VALUES;"
# Expected: ERROR: cannot execute INSERT in a read-only transaction
```

### Check 2.3 — MinIO DC2 healthy

```bash
# Local-test: port 9002; two-VM: port 9000
curl -s http://localhost:9002/minio/health/live && echo "MinIO DC2: OK"
```

---

## Phase 3 — MinIO Site Replication

Run once after both MinIO instances are healthy.

```bash
# Option A: using the mc container (no local mc install needed)
docker run --rm --network host \
  --env-file .env \
  minio/mc:RELEASE.2024-11-17T19-35-25Z \
  alias set dc1 http://${DC1_IP}:9000 ${MINIO_ROOT_USER} ${MINIO_ROOT_PASSWORD}

docker run --rm --network host \
  --env-file .env \
  minio/mc:RELEASE.2024-11-17T19-35-25Z \
  alias set dc2 http://${DC1_IP}:9002 ${MINIO_ROOT_USER} ${MINIO_ROOT_PASSWORD}

docker run --rm --network host \
  --env-file .env \
  minio/mc:RELEASE.2024-11-17T19-35-25Z \
  admin replicate add dc1 dc2

# Option B: using local mc binary
source .env
mc alias set dc1 http://${DC1_IP}:9000 ${MINIO_ROOT_USER} ${MINIO_ROOT_PASSWORD}
mc alias set dc2 http://${DC1_IP}:9002 ${MINIO_ROOT_USER} ${MINIO_ROOT_PASSWORD}
mc admin replicate add dc1 dc2
```

### Check 3.1 — Replication active

```bash
mc admin replicate info dc1
# Expected: site replication enabled, both sites listed
```

### Check 3.2 — Data replicates

```bash
# Create bucket and upload on DC1
mc mb dc1/test-bucket
echo "hello dc-dr" > /tmp/test.txt
mc cp /tmp/test.txt dc1/test-bucket/

# Read from DC2 (should appear within seconds)
mc ls dc2/test-bucket/
mc cat dc2/test-bucket/test.txt
# Expected: hello dc-dr
```

---

## Phase 4 — Verify Monitoring

```bash
# Grafana (default creds: admin / admin)
open http://localhost:3000

# Prometheus targets — all should be UP
open http://localhost:9090/targets
```

---

## Deployment Checklist

```
[ ] DC1 Patroni leader confirmed (curl /leader returns pg-dc1)
[ ] DC2 replica streaming at lag=0
[ ] Witness node visible in /cluster with nofailover tag
[ ] Replication test table visible on DC2
[ ] MinIO site replication active (mc admin replicate info dc1)
[ ] Test object replicates DC1→DC2 and DC2→DC1
[ ] Grafana dashboards loading
[ ] Prometheus postgres_exporter target is UP
```
