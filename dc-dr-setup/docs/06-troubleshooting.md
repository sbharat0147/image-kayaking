# Troubleshooting & Debug Guide

---

## Quick Diagnostics

```bash
# All Patroni containers status
docker ps --filter name=postgres

# Cluster topology
curl -s http://localhost:8008/cluster | python3 -m json.tool

# Patroni detailed status on each node
curl -s http://localhost:8008/patroni | python3 -m json.tool   # DC1
curl -s http://localhost:8009/patroni | python3 -m json.tool   # DC2
curl -s http://localhost:8010/patroni | python3 -m json.tool   # witness

# Live logs (follow)
docker logs -f postgres-dc1
docker logs -f postgres-dc2
docker logs -f postgres-witness
```

---

## Issue: DC2 does not promote after DC1 goes down

**Symptoms**: After stopping DC1, DC2 log shows:
```
no action. I am (pg-dc2), a secondary, and following a leader (pg-dc1)
```
or
```
Lock owner: None; I am pg-dc2, a secondary, and following a leader
```

**Diagnoses**:

1. **Raft quorum not reached** — witness not in the same Raft cluster as DC2

```bash
# Check if all 3 nodes see each other in Raft
docker exec postgres-dc2 \
  python3 -c "
import yaml
with open('/tmp/patroni-rendered.yml') as f:
    c = yaml.safe_load(f)
print('self_addr:', c['raft']['self_addr'])
print('partner_addrs:', c['raft'].get('partner_addrs'))
"
```

Expected: `self_addr: 172.30.0.20:5010`, `partner_addrs: ['172.30.0.10:5010', '172.30.0.30:5010']`

2. **Wrong network IP** — Raft bound on one interface, peers connecting on another

```bash
# From DC2, check what IP witness resolves to
docker exec postgres-dc2 getent hosts postgres-witness
# If this returns a dc2-internal IP (172.23.x.x) instead of 172.30.0.30,
# DNS is broken — static IPs must be used (already fixed in current config)

# Check actual Raft bind address in logs
docker logs postgres-dc2 2>&1 | grep -E 'raft|bind|5010'
```

**Fix**: Ensure all three compose files assign static IPs on `patroni-cluster` network
(172.30.0.10, .20, .30) and all patroni YAMLs use those IPs for raft.self_addr and partner_addrs.

3. **Stale Raft state on disk** — old membership prevents new nodes from joining

```bash
# Wipe all Raft data and restart clean
docker compose -p dc2 -f docker-compose.dc2-local.yml down
docker compose -p dc1 -f docker-compose.dc1.yml down
docker volume rm dc1_pg_raft_dc1 dc2_pg_raft_dc2 dc2_pg_raft_witness
docker network rm patroni-cluster
# Then restart in order: DC1 first, DC2+witness after 30s
```

---

## Issue: DC1 tries to bootstrap but shows "failed to acquire initialize lock"

**Symptom**: DC1 log loops on:
```
failed to acquire initialize lock
```

**Cause A**: DC1's partner_addrs point to DC2/witness but those aren't up yet,
so DC1 can't form quorum to initialize.

**Fix**: The entrypoint.sh detects first boot (no PG_VERSION) + bootstrap.initdb config
and strips partner_addrs so DC1 bootstraps as a solo 1-node Raft cluster.
Verify the entrypoint logic ran:

```bash
docker logs postgres-dc1 2>&1 | grep 'entrypoint'
# Expected: [entrypoint] First boot + initdb config found: starting as 1-node Raft cluster
```

If this line is missing, the volume may have an old PG_VERSION from a previous run.
Wipe the data volume: `docker volume rm dc1_pg_data_dc1` and restart.

**Cause B**: Another Patroni node already holds the DCS lock (bootstrapped as primary).

```bash
docker logs postgres-dc1 2>&1 | grep 'initialize'
# If DC2 bootstrapped as primary, you'll see DC2 holding the lock
```

Fix: Wipe all volumes and restart in order (DC1 first).

---

## Issue: DC2 starts but shows "cloning from..." then fails

**Symptom**:
```
pg_basebackup: error: could not connect to the server
```
or
```
cloning from primary: ERROR
```

**Cause**: DC1 PostgreSQL not yet accepting replication connections, or `pg_hba.conf`
doesn't allow the replicator user from DC2's IP.

**Check**:

```bash
# On DC1, check pg_hba allows replication
psql -h localhost -p 5432 -U postgres \
  -c "SELECT * FROM pg_hba_file_rules WHERE type='host';"

# The bootstrap.pg_hba in patroni.dc1.yml should have included:
# host replication replicator 0.0.0.0/0 md5

# Force DC2 to re-clone
docker exec postgres-dc1 \
  patronictl -c /tmp/patroni-rendered.yml \
  reinit pg-cluster pg-dc2 --force
```

---

## Issue: pg_rewind fails when DC1 rejoins

**Symptom**: DC1 log shows:
```
pg_rewind: error: ...
could not find common ancestor
```

**Cause**: WAL segments needed for rewind have been recycled on DC2.

**Fix**: Force full re-clone of DC1 from DC2:

```bash
# Stop DC1 patroni container
docker compose -p dc1 -f docker-compose.dc1.yml stop postgres-patroni

# Wipe DC1 data (NOT raft — raft is fine)
docker volume rm dc1_pg_data_dc1

# Restart DC1 — entrypoint sees no PG_VERSION, pg_basebackup clones from DC2
docker compose -p dc1 -f docker-compose.dc1.yml --env-file .env up -d postgres-patroni
```

---

## Issue: Timeline mismatch / WAL LSN errors on DC2

**Symptom**:
```
requested WAL segment ... has already been removed
```
or DC2 lag grows and never recovers.

**Fix**: Reinit DC2 from the current primary:

```bash
# Find current primary
curl -s http://localhost:8008/cluster | python3 -m json.tool

# Reinit from whichever node is leader
docker exec postgres-dc1 \
  patronictl -c /tmp/patroni-rendered.yml \
  reinit pg-cluster pg-dc2 --force
```

---

## Issue: Patroni REST API not responding (port 8008 times out)

```bash
# Check container is running
docker ps | grep postgres-dc1

# Check logs for crash
docker logs --tail 50 postgres-dc1

# Check if patroni process is alive inside container
docker exec postgres-dc1 ps aux | grep patroni

# Check if port is bound
docker exec postgres-dc1 ss -tlnp | grep 8008
```

---

## Issue: PostgreSQL data directory permissions error

**Symptom**:
```
could not open file "...": Permission denied
```
or
```
initdb: error: could not change permissions of directory
```

**Cause**: Docker volume mounted as root; postgres user can't write.

**Fix**: The entrypoint.sh handles this via `chown -R postgres:postgres` before
Patroni starts. If the error persists:

```bash
# Manually fix permissions (runs entrypoint as root before gosu)
docker exec -u root postgres-dc1 \
  chown -R postgres:postgres /home/postgres/data /home/postgres/raft
```

---

## Issue: MinIO site replication not syncing

```bash
# Check replication status
mc admin replicate info dc1

# Check for backlog
mc admin replicate backlog dc1

# Force resync
mc admin replicate resync start dc1 --site dc2
mc admin replicate resync status dc1

# Check MinIO container logs
docker logs minio-dc1 | tail -50
docker logs minio-dc2 | tail -50
```

---

## Issue: Docker network conflict — patroni-cluster already exists

```bash
# If network has wrong subnet from a previous run
docker network inspect patroni-cluster | grep Subnet

# If it shows a different subnet than 172.30.0.0/24:
# Stop all containers first
docker compose -p dc2 -f docker-compose.dc2-local.yml down
docker compose -p dc1 -f docker-compose.dc1.yml down

# Remove the network
docker network rm patroni-cluster

# Restart (DC1 compose will recreate it with correct subnet)
```

---

## Issue: DC2 Compose accidentally recreates DC1 containers

**Symptom**: Running DC2 compose overwrites DC1 postgres container.

**Cause**: Compose file run without `-p dc2` project flag.

**Rule**: Always use explicit project names:
```bash
# DC1
docker compose -p dc1 -f docker-compose.dc1.yml ...

# DC2
docker compose -p dc2 -f docker-compose.dc2-local.yml ...
```

---

## Useful Debug Commands

```bash
# Show Patroni rendered config (after env var substitution)
docker exec postgres-dc1 cat /tmp/patroni-rendered.yml

# Show PostgreSQL logs inside container
docker exec postgres-dc1 tail -100 /home/postgres/data/log/postgresql-*.log 2>/dev/null \
  || docker exec postgres-dc1 cat /home/postgres/data/pg_log/postgresql-*.log 2>/dev/null \
  || docker logs postgres-dc1 2>&1 | grep -i postgres

# Raft peer connectivity test (from DC2, can it reach DC1 on Raft port?)
docker exec postgres-dc2 bash -c "echo > /dev/tcp/172.30.0.10/5010 && echo OPEN || echo CLOSED"
docker exec postgres-dc2 bash -c "echo > /dev/tcp/172.30.0.30/5010 && echo OPEN || echo CLOSED"

# Check which IP a container name resolves to (helps debug DNS issues)
docker exec postgres-dc2 getent hosts postgres-dc1
docker exec postgres-witness getent hosts postgres-dc2

# Show Docker networks a container is on
docker inspect postgres-dc2 --format '{{json .NetworkSettings.Networks}}' | python3 -m json.tool

# PostgreSQL replication slots (prevent WAL accumulation)
psql -h localhost -p 5432 -U postgres \
  -c "SELECT slot_name, active, pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS lag FROM pg_replication_slots;"

# Timeline history (shows every failover event)
docker exec postgres-dc1 \
  patronictl -c /tmp/patroni-rendered.yml history pg-cluster
```

---

## Log Locations

| Component | Where to find logs |
|---|---|
| Patroni | `docker logs postgres-dc1` (Patroni writes to stdout) |
| PostgreSQL | Inside container: `/home/postgres/data/log/` |
| MinIO | `docker logs minio-dc1` |
| Prometheus | `docker logs prometheus` |
| Grafana | `docker logs grafana` |
