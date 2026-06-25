# DC/DR Setup — Documentation Index

| Doc | Purpose |
|---|---|
| [01-architecture.md](01-architecture.md) | System design, component roles, network layout, port map |
| [02-airgap-bundle.md](02-airgap-bundle.md) | Build Docker image bundle on internet machine, ship to airgap, load & verify |
| [03-deployment-runbook.md](03-deployment-runbook.md) | Step-by-step first-time deployment: DC1 → DC2 → MinIO replication → monitoring |
| [04-operations-runbook.md](04-operations-runbook.md) | Day-2 operations: failover, switchover, rejoin, reinit, patronictl reference |
| [05-minio-dcdr.md](05-minio-dcdr.md) | MinIO site replication setup and full test suite |
| [06-troubleshooting.md](06-troubleshooting.md) | Diagnosis commands and fixes for every known failure mode |
| [07-enterprise-test-scenarios.md](07-enterprise-test-scenarios.md) | Full test suite: S1–S9 covering all HA and DR scenarios with pass criteria |
| [08-airgap-developer-setup.md](08-airgap-developer-setup.md) | **Developer manual** — build the airgap bundle on an internet machine, transfer and deploy on two airgap VMs, final checklist |
| [09-tester-manual.md](09-tester-manual.md) | **Tester manual** — 23 test cases across Phase 1 (internet/local) and Phase 2 (airgap/two-VM): PostgreSQL HA, MinIO DR, monitoring alerts, MCP Server, airgap isolation |
| [10-postgresql-concepts-and-observations.md](10-postgresql-concepts-and-observations.md) | **PostgreSQL HA concepts** for newcomers — WAL timelines, replication slots, pg_rewind, connect_address pitfall, Raft quorum; every section backed by a real observed error |
| [11-local-test-setup-runbook.md](11-local-test-setup-runbook.md) | **Local test runbook** — definitive step-by-step guide to spin up, verify, and tear down the full DC/DR stack on a single machine; includes port reference, credentials, checkpoints, failover/switchover tests, and troubleshooting table |
| [12-test-execution-record.md](12-test-execution-record.md) | **Test execution record** — 13 test cases (TC-PG, TC-FAIL, TC-MINIO, TC-MON) each with intent, exact commands, expected output, pass criteria, and actual results; data integrity audit across all failover/switchover events |
| [13-airgap-rhel9-setup.md](13-airgap-rhel9-setup.md) | **RHEL 9 airgap guide** — Build a fully self-contained bundle (Docker images + Docker CE RPMs + podman-compose wheels + jq binary + install scripts), transfer to airgap VMs, install Docker CE or Podman, and deploy the full DC/DR stack — no internet required on target VMs |

## Quick Reference

```bash
# Cluster health
curl -s http://localhost:8008/cluster | python3 -m json.tool

# Who is primary right now?
curl -s http://localhost:8008/leader       # DC1 view
curl -s http://localhost:8009/leader       # DC2 view

# Start DC1
docker compose -p dc1 -f docker-compose.dc1.yml --env-file .env up -d

# Start DC2 + witness (local-test)
docker compose -p dc2 -f docker-compose.dc2-local.yml --env-file .env up -d

# Graceful switchover DC1 → DC2
docker exec postgres-dc1 patronictl -c /tmp/patroni-rendered.yml \
  switchover pg-cluster --master pg-dc1 --candidate pg-dc2 --force

# Full health check script
DC1_IP=localhost DC2_IP=localhost ./scripts/failover-check.sh
```
