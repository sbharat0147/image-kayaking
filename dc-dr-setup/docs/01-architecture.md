# DC/DR Architecture Reference

## Overview

Two Docker hosts (DC1 = primary, DC2 = DR) running a fully open-source, airgap-capable
high-availability stack for PostgreSQL and MinIO. A lightweight witness node co-located
on the DC2 host provides the third Raft vote for automatic failover without a third VM.

```
┌──────────────────────────────────────────────┐   ┌──────────────────────────────────────────────┐
│                   DC1 (Primary)              │   │              DC2 (DR / Replica)              │
│                                              │   │                                              │
│  ┌─────────────────────────────────────────┐ │   │ ┌─────────────────────────────────────────┐  │
│  │  postgres-dc1  (Patroni + PostgreSQL 16)│─┼───┼▶│  postgres-dc2  (Patroni + PostgreSQL 16)│  │
│  │  Raft: 172.30.0.10:5010               │ │WAL│ │  Raft: 172.30.0.20:5010               │  │
│  │  PG:   172.30.0.10:5432               │ │str│ │  PG:   172.30.0.20:5432 (host: 5433)  │  │
│  └─────────────────────────────────────────┘ │eam│ └─────────────────────────────────────────┘  │
│                                              │ing│                                              │
│  ┌─────────────────────────────────────────┐ │   │ ┌─────────────────────────────────────────┐  │
│  │  minio-dc1  (MinIO)                     │◀┼───┼▶│  minio-dc2  (MinIO)                     │  │
│  │  Port 9000/9001                         │ │bidi│  Port 9002/9003                         │  │
│  └─────────────────────────────────────────┘ │rep│ └─────────────────────────────────────────┘  │
│                                              │   │                                              │
│  ┌─────────────────────────────────────────┐ │   │ ┌─────────────────────────────────────────┐  │
│  │  Prometheus + Grafana + Alertmanager    │ │   │ │  postgres-witness  (Patroni, nofailover)│  │
│  │  Ports 9090, 3000, 9093                 │ │   │ │  Raft: 172.30.0.30:5010               │  │
│  └─────────────────────────────────────────┘ │   │ └─────────────────────────────────────────┘  │
└──────────────────────────────────────────────┘   └──────────────────────────────────────────────┘

                     patroni-cluster Docker network  172.30.0.0/24 (shared)
                     DC1: 172.30.0.10   DC2: 172.30.0.20   Witness: 172.30.0.30
```

## Component Roles

| Container | Role | Failover behaviour |
|---|---|---|
| postgres-dc1 | Patroni leader + PostgreSQL primary | Steps down when DC1 loses quorum |
| postgres-dc2 | Patroni replica + PostgreSQL standby | Promotes to primary when DC1 is gone and witness votes |
| postgres-witness | Raft voter only (nofailover, noloadbalance) | Provides 2/3 quorum so DC2 can promote; never becomes PG primary |
| minio-dc1 | MinIO S3-compatible object store | Site-replication peer; DC1 side |
| minio-dc2 | MinIO S3-compatible object store | Site-replication peer; DC2 side |

## Raft Quorum Design

```
Nodes: DC1 + DC2 + Witness = 3 voters
Quorum required: 2 of 3

Scenario                    Voters available   Quorum?   Result
──────────────────────────  ─────────────────  ────────  ─────────────────────
All healthy                 3/3                ✓         Normal operation
DC1 down                    DC2 + Witness      ✓         DC2 auto-promotes
DC2 down                    DC1 + Witness      ✓         DC1 stays primary
Witness down                DC1 + DC2          ✓         Normal operation
DC1 + Witness down          DC2 alone (1/3)    ✗         No promotion (split-brain safe)
DC2 + Witness down          DC1 alone (1/3)    ✗         DC1 read-only (safe)
```

## Network Layout

### Local-test mode (single VM, offset ports)

```
Host port  → Container       Purpose
─────────────────────────────────────────────────────
5432       → postgres-dc1    PostgreSQL primary
5433       → postgres-dc2    PostgreSQL replica
5434       → postgres-witness PostgreSQL witness
8008       → postgres-dc1    Patroni REST API
8009       → postgres-dc2    Patroni REST API
8010       → postgres-witness Patroni REST API
9000/9001  → minio-dc1       MinIO S3 / Console
9002/9003  → minio-dc2       MinIO S3 / Console
9090       → prometheus
3000       → grafana
9093       → alertmanager
```

### Two-VM production mode

```
DC1 VM (DC1_IP):   5432, 8008, 9000, 9001, 9090, 3000, 9093
DC2 VM (DC2_IP):   5432, 8008, 9000, 9001, 8009, 8010
                   (DC2 and witness use standard ports on their own VM)
```

## Technology Stack

| Component | Version | Image |
|---|---|---|
| PostgreSQL | 16 (Bookworm) | `postgres:16-bookworm` (base) |
| Patroni | 3.3.0 | `local/patroni:3.3.0` (built locally) |
| Raft DCS | pysyncobj (Patroni built-in) | included in Patroni |
| MinIO | RELEASE.2025-05-24T17-08-30Z | `minio/minio` |
| Prometheus | v2.52.0 | `prom/prometheus` |
| Grafana | 11.0.0 | `grafana/grafana-oss` |
| Alertmanager | v0.27.0 | `prom/alertmanager` |
| postgres_exporter | v0.15.0 | `prometheuscommunity/postgres-exporter` |
