# DC/DR Setup Plan — PostgreSQL + MinIO (100% Open Source)

## Overview

Two VMs in separate datacenters (DC1 = primary, DC2 = DR), each running Docker.
PostgreSQL and MinIO are replicated continuously so failover can happen with
minimal data loss and minimal manual steps.

```
┌─────────────────────────────────┐        ┌─────────────────────────────────┐
│           DC1 (Primary)         │        │           DC2 (DR)              │
│                                 │        │                                 │
│  ┌──────────────────────────┐   │        │  ┌──────────────────────────┐   │
│  │   Patroni (pg-primary)   │──────────▶│  │  Patroni (pg-replica)   │   │
│  │   PostgreSQL + WAL arch  │   │  WAL   │  │  PostgreSQL standby      │   │
│  └──────────────────────────┘   │        │  └──────────────────────────┘   │
│                                 │        │                                 │
│  ┌──────────────────────────┐   │        │  ┌──────────────────────────┐   │
│  │    MinIO (site peer)     │◀─────────▶│  │    MinIO (site peer)     │   │
│  │    bucket replication    │   │  SYNC  │  │    bucket replication    │   │
│  └──────────────────────────┘   │        │  └──────────────────────────┘   │
│                                 │        │                                 │
│  ┌──────────────────────────┐   │        │  ┌──────────────────────────┐   │
│  │  etcd (DCS for Patroni)  │◀─────────▶│  │  etcd (DCS for Patroni)  │   │
│  └──────────────────────────┘   │        │  └──────────────────────────┘   │
│                                 │        │                                 │
│  ┌──────────────────────────┐   │        │  ┌──────────────────────────┐   │
│  │  Prometheus + Grafana    │   │        │  │  Alertmanager (standby)  │   │
│  └──────────────────────────┘   │        │  └──────────────────────────┘   │
└─────────────────────────────────┘        └─────────────────────────────────┘
```

---

## Component Decisions

| Need | Tool | Why |
|------|------|-----|
| PostgreSQL HA / failover | **Patroni** | Industry-standard, free, uses etcd as DCS |
| Distributed consensus | **etcd** | Used by Patroni for leader election |
| WAL archiving | **pgBackRest** | Free, supports MinIO (S3) as archive target |
| MinIO replication | **MinIO Site Replication** | Built-in, zero-cost, bidirectional |
| Periodic full backups | **pgBackRest** | Incremental + differential, stores to MinIO |
| Monitoring | **Prometheus + Grafana** | Free; postgres_exporter + minio metrics endpoint |
| Alerting | **Alertmanager** | Free, bundled with Prometheus |
| Container orchestration | **Docker Compose** | Simple, no Kubernetes needed |

---

## Replication Strategy

### PostgreSQL

- **Streaming replication** (built-in WAL shipping) from DC1 → DC2 continuously.
- **Patroni** wraps both instances; etcd quorum decides who is primary.
- **pgBackRest** archives WALs to local MinIO on DC1. DC2 MinIO receives those
  archives via MinIO Site Replication, so DC2 can also do PITR independently.
- RPO: seconds (streaming lag). RTO: ~30–60 s automatic (Patroni failover).

### MinIO

- **MinIO Site Replication** (introduced in MinIO RELEASE.2022-09): both sites
  are peers; all buckets, objects, IAM policies replicate bidirectionally.
- This covers the pgBackRest WAL archive bucket automatically.
- RPO: near-zero (async replication, typically < 1 s on good links).
- RTO: zero for reads (DC2 already has a full copy); write endpoint switch is
  a config/DNS change.

---

## Network Requirements

| Traffic | Port | Direction |
|---------|------|-----------|
| PG streaming replication | 5432 | DC1 ↔ DC2 |
| etcd peer | 2380 | DC1 ↔ DC2 |
| etcd client | 2379 | DC1 ↔ DC2 |
| MinIO S3 API | 9000 | DC1 ↔ DC2 |
| pgBackRest TLS | 8432 | DC1 ↔ DC2 |
| Prometheus scrape | 9187, 9001 | internal |

Firewall: open only the ports above between DC1 and DC2. Use TLS everywhere.

---

## Directory Layout (this repo)

```
dc-dr-setup/
├── PLAN.md                    ← this file
├── docker-compose.dc1.yml     ← DC1 stack
├── docker-compose.dc2.yml     ← DC2 stack
├── .env.example               ← variables to copy to .env on each VM
├── postgres/
│   ├── postgresql.conf        ← shared PG tuning
│   ├── pg_hba.conf            ← replication + app access rules
│   └── pgbackrest.conf        ← pgBackRest config (MinIO as repo)
├── patroni/
│   ├── patroni.dc1.yml        ← Patroni config for DC1 node
│   └── patroni.dc2.yml        ← Patroni config for DC2 node
├── minio/
│   └── mc-site-replication.sh ← one-shot script to wire up site replication
├── monitoring/
│   ├── prometheus.yml         ← scrape config
│   ├── alerting-rules.yml     ← PG + MinIO alert rules
│   └── grafana-provisioning/  ← dashboards as JSON
└── scripts/
    ├── failover-check.sh      ← manual health probe
    ├── dr-promote.sh          ← emergency: promote DC2 PG to primary
    └── backup-verify.sh       ← verify latest pgBackRest backup
```

---

## Step-by-Step Setup

### Phase 1 — Bootstrap both VMs

```bash
# On BOTH VMs
sudo apt-get update && sudo apt-get install -y docker.io docker-compose-plugin git
sudo usermod -aG docker $USER
# clone this repo
git clone <repo-url> ~/image-kayaking
cd ~/image-kayaking/dc-dr-setup
cp .env.example .env
# fill in DC1_IP, DC2_IP, PG passwords, MinIO keys in .env
```

### Phase 2 — etcd cluster (3 nodes or 2 nodes + arbiter)

> For a 2-VM setup: run one etcd each + one lightweight etcd-proxy/arbiter
> (can run as a tiny container on either VM). A 3-node etcd needs a third host
> (a $5 VPS, or an arbiter container on DC2 counts as 2 votes).

Simplest 2-VM approach: run etcd in "discovery" mode with a static peer list.
Patroni will use these two etcd nodes; split-brain is prevented because Patroni
requires a quorum write to etcd before promoting.

### Phase 3 — Start PostgreSQL with Patroni

```bash
# DC1
docker compose -f docker-compose.dc1.yml up -d etcd postgres-patroni

# DC2 (after DC1 is running and registered in etcd)
docker compose -f docker-compose.dc2.yml up -d etcd postgres-patroni
```

Patroni will:
1. DC1 initialises the cluster, becomes primary.
2. DC2 joins as a replica via streaming replication.
3. etcd holds the leader lock; either node can take over.

### Phase 4 — Configure pgBackRest with MinIO

```bash
# On DC1, after MinIO is up on both VMs
docker exec postgres-dc1 pgbackrest --stanza=main stanza-create
docker exec postgres-dc1 pgbackrest --stanza=main --type=full backup
```

pgBackRest writes to MinIO DC1 bucket → MinIO Site Replication copies to DC2
bucket → DC2 can restore independently.

### Phase 5 — MinIO Site Replication

```bash
# Run once from any host that can reach both MinIO instances
bash minio/mc-site-replication.sh
```

The script registers both sites as peers; replication is then automatic.

### Phase 6 — Monitoring

```bash
docker compose -f docker-compose.dc1.yml up -d prometheus grafana alertmanager
```

Grafana is pre-provisioned with:
- PostgreSQL dashboard (replication lag, connections, TPS)
- MinIO dashboard (object counts, replication lag, errors)

---

## Failover Runbook

### Automatic (Patroni handles it)

If DC1 PostgreSQL goes down:
1. Patroni detects loss of etcd leader lock.
2. DC2 Patroni wins the election and promotes the replica.
3. Apps should point to a DNS name (`pg.internal`) that is updated by a
   Patroni callback script.
4. No human action needed for PostgreSQL.

MinIO on DC2 is already a full peer — apps switch endpoint to DC2 MinIO URL.

### Manual (emergency promote)

```bash
# On DC2 VM
bash scripts/dr-promote.sh
```

This calls `patronictl failover` and updates the local `/etc/hosts` or DNS
override so apps on DC2 use the local PG.

---

## Recovery Point / Recovery Time Targets

| Component | RPO | RTO |
|-----------|-----|-----|
| PostgreSQL (streaming) | ~0–5 s | 30–90 s (Patroni auto) |
| PostgreSQL (pgBackRest PITR) | last WAL archive (~1 min) | ~5–15 min manual |
| MinIO objects | ~0–30 s (site replication) | 0 (DC2 already live) |

---

## Cost

| Tool | Cost |
|------|------|
| Patroni | Free (MIT) |
| etcd | Free (Apache 2) |
| pgBackRest | Free (MIT) |
| MinIO (community) | Free (AGPLv3) |
| Prometheus / Grafana OSS | Free (Apache 2) |
| Docker / Compose | Free |
| **Total** | **$0** |

Only cost is the VM/cloud compute for DC2.

---

## Open Items / Decisions Needed

1. **etcd quorum**: 2 VMs = 2 etcd nodes (no quorum if both partitioned).
   Recommended: add a tiny $5 arbiter VM or use etcd's "learner" mode.
2. **DNS / VIP**: How do app clients find the current PG primary?
   Options: (a) update `/etc/hosts` via Patroni callback, (b) HAProxy on each
   VM, (c) cloud DNS with short TTL, (d) pgBouncer pointing to Patroni REST API.
3. **MinIO TLS**: Self-signed certs are fine for internal DC links; add a CA if
   you want browsers/external clients to trust the console.
4. **Backup retention**: pgBackRest defaults — 2 full + 7 days WAL.
   Adjust in `pgbackrest.conf`.
