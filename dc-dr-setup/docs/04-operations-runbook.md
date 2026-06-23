# Operations Runbook — Day-2 Operations

---

## Daily Health Check

```bash
# Full cluster state
curl -s http://localhost:8008/cluster | python3 -m json.tool

# Replication lag (should be 0 or <1s)
psql -h localhost -p 5432 -U postgres \
  -c "SELECT client_addr, state, sent_lsn, write_lsn, flush_lsn, replay_lsn,
             (sent_lsn - replay_lsn) AS lag_bytes
      FROM pg_stat_replication;"

# MinIO health
curl -s http://localhost:9000/minio/health/live && echo DC1 OK
curl -s http://localhost:9002/minio/health/live && echo DC2 OK

# MinIO replication status
mc admin replicate info dc1
```

---

## Scenario 1 — Planned Maintenance on DC1 (Graceful Switchover)

Use this for patching, upgrades, or scheduled maintenance on DC1.
Zero data loss. DC2 becomes primary, then DC1 comes back as replica.

```bash
# Step 1: Confirm DC2 lag is 0
curl -s http://localhost:8008/cluster | python3 -m json.tool

# Step 2: Graceful switchover
docker exec postgres-dc1 \
  patronictl -c /tmp/patroni-rendered.yml \
  switchover pg-cluster \
  --master pg-dc1 --candidate pg-dc2 --force

# Step 3: Confirm DC2 is now leader
curl -s http://localhost:8008/cluster | python3 -m json.tool
# pg-dc2: leader, pg-dc1: replica

# Step 4: Perform maintenance on DC1...

# Step 5: Switchback to DC1 (optional, after maintenance)
docker exec postgres-dc2 \
  patronictl -c /tmp/patroni-rendered.yml \
  switchover pg-cluster \
  --master pg-dc2 --candidate pg-dc1 --force
```

---

## Scenario 2 — DC1 Failure (Automatic Failover)

When DC1 goes down, DC2 and the witness form a 2/3 quorum and promote DC2.
This happens automatically within ttl (30s) + loop_wait (10s) ≈ 40 seconds.

**Monitoring**: Watch for promotion in logs:

```bash
docker logs -f postgres-dc2 2>&1 | grep -E 'promoted|leader|failover'
```

**Verify DC2 is now primary**:

```bash
curl -s http://localhost:8009/leader
# Returns: pg-dc2

# DC2 should now accept writes
psql -h localhost -p 5433 -U postgres \
  -c "INSERT INTO repl_test DEFAULT VALUES; SELECT count(*) FROM repl_test;"
```

---

## Scenario 3 — DC1 Rejoins After Failure

After fixing DC1, simply start it. Patroni will automatically:
1. Detect the timeline divergence
2. Run `pg_rewind` to rewind DC1 to the failover point
3. Start DC1 as a streaming replica of DC2

```bash
# Start DC1 (data volume still intact — no wipe needed)
docker compose -p dc1 -f docker-compose.dc1.yml --env-file .env up -d postgres-patroni

# Watch DC1 come back as replica (~60s for pg_rewind + streaming start)
watch -n 5 'curl -s http://localhost:8009/cluster | python3 -m json.tool'
# pg-dc1: replica, lag decreasing to 0
```

**If pg_rewind fails** (timeline too far diverged or WAL not available):

```bash
# Force reinitialize DC1 from DC2 (full pg_basebackup — data loss window)
docker exec postgres-dc2 \
  patronictl -c /tmp/patroni-rendered.yml \
  reinit pg-cluster pg-dc1 --force
```

---

## Scenario 4 — Manual Failover (Force Promote DC2)

Use only when DC1 is confirmed dead and automatic failover hasn't triggered.

```bash
docker exec postgres-dc2 \
  patronictl -c /tmp/patroni-rendered.yml \
  failover pg-cluster --master pg-dc1 --candidate pg-dc2 --force
```

---

## Scenario 5 — Pause / Resume Patroni (Maintenance Mode)

Pausing prevents Patroni from changing topology during planned work.

```bash
# Pause automatic failover
docker exec postgres-dc1 \
  patronictl -c /tmp/patroni-rendered.yml pause pg-cluster

# Do your maintenance...

# Resume
docker exec postgres-dc1 \
  patronictl -c /tmp/patroni-rendered.yml resume pg-cluster
```

---

## Scenario 6 — DC2 Full Resync (Reinit)

When DC2's data is too far behind or corrupted:

```bash
docker exec postgres-dc1 \
  patronictl -c /tmp/patroni-rendered.yml \
  reinit pg-cluster pg-dc2 --force

# Watch DC2 re-clone from DC1
docker logs -f postgres-dc2 2>&1 | grep -E 'basebackup|clone|replica'
```

---

## Scaling / Config Changes

### Change a PostgreSQL parameter

Edit `postgres/postgresql.conf`, then reload:

```bash
psql -h localhost -p 5432 -U postgres -c "SELECT pg_reload_conf();"
```

For parameters requiring restart, use Patroni:

```bash
docker exec postgres-dc1 \
  patronictl -c /tmp/patroni-rendered.yml \
  restart pg-cluster pg-dc1 --force
```

### Update Patroni DCS settings (ttl, loop_wait, etc.)

```bash
# Edit the DCS config dynamically (no restart needed)
docker exec postgres-dc1 \
  patronictl -c /tmp/patroni-rendered.yml \
  edit-config pg-cluster
```

---

## Useful patronictl Commands

```bash
# All commands run inside any Patroni container:
docker exec postgres-dc1 patronictl -c /tmp/patroni-rendered.yml <command>

# Commands:
list pg-cluster               # same as /cluster API
topology pg-cluster           # visual tree view
history pg-cluster            # timeline history (shows failover events)
show-config pg-cluster        # current DCS config
switchover pg-cluster         # graceful primary switch
failover pg-cluster           # forced failover
reinit pg-cluster <node>      # re-clone a node from primary
pause pg-cluster              # disable automatic failover
resume pg-cluster             # re-enable automatic failover
restart pg-cluster <node>     # restart PostgreSQL on a node
reload pg-cluster <node>      # reload patroni config
```

---

## Restart Procedures

### Restart a single Patroni node safely

```bash
# Graceful restart via patronictl (preferred — reloads config, waits for replica sync)
docker exec postgres-dc1 \
  patronictl -c /tmp/patroni-rendered.yml \
  restart pg-cluster pg-dc1

# Hard restart via Docker (use only if patronictl is unresponsive)
docker restart postgres-dc1
```

### Full stack restart (ordered)

```bash
# 1. Stop DC2 first to avoid split-brain during shutdown
docker compose -p dc2 -f docker-compose.dc2-local.yml stop postgres-witness postgres-patroni

# 2. Stop DC1
docker compose -p dc1 -f docker-compose.dc1.yml stop postgres-patroni

# 3. Start DC1 first
docker compose -p dc1 -f docker-compose.dc1.yml --env-file .env up -d postgres-patroni
sleep 30

# 4. Start DC2 + witness
docker compose -p dc2 -f docker-compose.dc2-local.yml --env-file .env up -d
```

---

## Backup (pgBackRest — Phase 7)

> pgBackRest archiving is disabled until MinIO and the pgbackrest stanza are configured.
> When ready, enable `archive_mode: on` and `archive_command` in patroni configs,
> then run `pgbackrest --stanza=main stanza-create` and `pgbackrest --stanza=main backup --type=full`.
