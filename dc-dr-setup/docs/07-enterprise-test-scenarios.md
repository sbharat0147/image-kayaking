# Enterprise Test Scenarios

All scenarios assume the cluster is healthy before starting:
- `curl -s http://localhost:8008/cluster` shows DC1=leader, DC2=replica, witness=replica
- Replication lag = 0

---

## PostgreSQL Scenarios

### S1 — Automatic Failover (DC1 sudden failure)

```bash
# Simulate DC1 crash
docker compose -p dc1 -f docker-compose.dc1.yml stop postgres-patroni

# Measure time-to-promotion (target: <60s)
time bash -c 'until curl -sf http://localhost:8009/leader | grep -q pg-dc2; do sleep 2; done; echo PROMOTED'

# Verify DC2 accepts writes
psql -h localhost -p 5433 -U postgres \
  -c "INSERT INTO repl_test DEFAULT VALUES; SELECT count(*) FROM repl_test;"

# Verify timeline incremented
curl -s http://localhost:8009/cluster | python3 -m json.tool | grep timeline
```

**Pass criteria**: DC2 promotes within 60s, timeline=2, writes succeed.

---

### S2 — DC1 Rejoin as Replica

Continues from S1.

```bash
# Restart DC1 (data volume intact)
docker compose -p dc1 -f docker-compose.dc1.yml --env-file .env up -d postgres-patroni

# Write more data on DC2 while DC1 is coming back
psql -h localhost -p 5433 -U postgres \
  -c "INSERT INTO repl_test SELECT generate_series(1,100), now();"

# Watch DC1 rejoin (~60s for pg_rewind + streaming)
watch -n 5 'curl -s http://localhost:8009/cluster | python3 -m json.tool'

# Verify DC1 has all rows written during failover window
psql -h localhost -p 5432 -U postgres \
  -c "SELECT count(*) FROM repl_test;"
# Must match the count on DC2
```

**Pass criteria**: DC1 appears as replica with lag=0, all data present.

---

### S3 — Graceful Switchover (Zero Data Loss)

```bash
# Confirm lag=0 before switching
curl -s http://localhost:8008/cluster | python3 -m json.tool

# Record row count
ROW_COUNT=$(psql -h localhost -p 5432 -U postgres -t -c "SELECT count(*) FROM repl_test;")

# Switchover
docker exec postgres-dc1 \
  patronictl -c /tmp/patroni-rendered.yml \
  switchover pg-cluster --master pg-dc1 --candidate pg-dc2 --force

# Verify DC2 is now leader on timeline+1 with same row count
sleep 10
psql -h localhost -p 5433 -U postgres \
  -c "SELECT count(*) FROM repl_test;"
# Must equal $ROW_COUNT exactly (zero data loss)

# Switchback to DC1
docker exec postgres-dc2 \
  patronictl -c /tmp/patroni-rendered.yml \
  switchover pg-cluster --master pg-dc2 --candidate pg-dc1 --force
```

**Pass criteria**: Exact row count preserved across switchover, no errors.

---

### S4 — Witness Failure (Cluster Remains Operational)

```bash
# Stop the witness
docker compose -p dc2 -f docker-compose.dc2-local.yml stop postgres-witness

# Verify cluster still works with 2/2 remaining nodes (DC1+DC2)
psql -h localhost -p 5432 -U postgres \
  -c "INSERT INTO repl_test DEFAULT VALUES;"

# DC1 should still be leader (still has quorum: 2 nodes, needs 2)
curl -s http://localhost:8008/cluster | python3 -m json.tool

# Restore witness
docker compose -p dc2 -f docker-compose.dc2-local.yml --env-file .env up -d postgres-witness
```

**Pass criteria**: Cluster remains writable during witness outage.

---

### S5 — Split-Brain Prevention

```bash
# Partition DC1 from DC2+witness by stopping the shared network interface
# (simulate network partition)
docker network disconnect patroni-cluster postgres-dc1

# DC1 should step down (loses quorum: 1/3, needs 2)
sleep 35  # ttl=30s
curl -s http://localhost:8008/patroni | python3 -m json.tool | grep role
# Expected: DC1 demotes to replica or read-only mode

# DC2 and witness have 2/3 quorum — DC2 promotes
curl -s http://localhost:8009/leader
# Expected: pg-dc2

# Reconnect DC1 to the network
docker network connect --ip 172.30.0.10 patroni-cluster postgres-dc1
# DC1 should rejoin as replica (no split-brain)
```

**Pass criteria**: Only one primary at any time. DC1 never accepts writes after losing quorum.

---

### S6 — High Replication Lag Recovery

```bash
# Generate heavy write load on DC1
psql -h localhost -p 5432 -U postgres \
  -c "INSERT INTO repl_test SELECT generate_series(1,100000), now();"

# Check lag
psql -h localhost -p 5432 -U postgres \
  -c "SELECT client_addr, state, (sent_lsn - replay_lsn) AS lag_bytes FROM pg_stat_replication;"

# Lag should recover to 0 automatically within seconds
# If lag exceeds maximum_lag_on_failover (1048576 bytes = 1MB),
# Patroni will not allow automatic promotion of that replica
```

---

### S7 — Connection Pool Behavior (application failover endpoint)

```bash
# Use the Patroni REST API as a health endpoint for load balancer
# Primary:
curl -s -o /dev/null -w "%{http_code}" http://localhost:8008/primary   # 200 if primary
curl -s -o /dev/null -w "%{http_code}" http://localhost:8008/replica   # 200 if replica

# Replica (DC2):
curl -s -o /dev/null -w "%{http_code}" http://localhost:8009/primary   # 503 if replica
curl -s -o /dev/null -w "%{http_code}" http://localhost:8009/replica   # 200 if replica

# Witness:
curl -s -o /dev/null -w "%{http_code}" http://localhost:8010/primary   # 503
curl -s -o /dev/null -w "%{http_code}" http://localhost:8010/replica   # 200 (but noloadbalance)
```

Configure your load balancer or HAProxy to check these endpoints and route
write traffic to the /primary endpoint and read traffic to /replica endpoints.

---

## MinIO Scenarios

### S8 — MinIO DC1 Failure, DC2 Continues Serving

```bash
# Write baseline data
mc mb dc1/failover-test 2>/dev/null || true
mc cp /etc/hostname dc1/failover-test/baseline.txt
sleep 5  # allow replication

# Stop DC1 MinIO
docker compose -p dc1 -f docker-compose.dc1.yml stop minio

# Verify DC2 serves existing data
mc cat dc2/failover-test/baseline.txt

# Write new data to DC2 during DC1 outage
echo "written during outage $(date)" | mc pipe dc2/failover-test/during-outage.txt

# Restore DC1 MinIO
docker compose -p dc1 -f docker-compose.dc1.yml up -d minio
sleep 20  # replication catch-up

# Verify object written during outage is on DC1
mc cat dc1/failover-test/during-outage.txt
```

**Pass criteria**: No data loss; DC1 auto-heals after reconnecting.

---

### S9 — Concurrent Writes to Both Sites

```bash
# Write to DC1 and DC2 simultaneously
for i in $(seq 1 10); do
  echo "dc1-object-$i" | mc pipe dc1/failover-test/dc1-obj-$i.txt &
  echo "dc2-object-$i" | mc pipe dc2/failover-test/dc2-obj-$i.txt &
done
wait

sleep 10  # replication

# Verify all 20 objects exist on both sites
mc ls dc1/failover-test/ | wc -l
mc ls dc2/failover-test/ | wc -l
# Both should show same count
```

**Pass criteria**: Both sites have identical object count; no conflicts.

---

## Test Results Checklist

```
Scenario  Description                          Pass/Fail  Notes
────────  ───────────────────────────────────  ─────────  ──────────────────
S1        Automatic failover DC1→DC2           [ ]
S2        DC1 rejoin as replica after failover [ ]
S3        Graceful switchover zero data loss   [ ]
S4        Witness failure (cluster stays up)   [ ]
S5        Split-brain prevention               [ ]
S6        High lag recovery                    [ ]
S7        REST health endpoint routing         [ ]
S8        MinIO DC1 failure, DC2 serves        [ ]
S9        Concurrent writes both sites         [ ]
```
