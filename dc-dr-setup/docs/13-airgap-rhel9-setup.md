# Airgap Setup Guide — RHEL 9

**Audience:** Engineer deploying the DC/DR stack on RHEL 9 VMs with no internet access.  
**Supersedes:** Docs 02 (airgap bundle) and 08 (developer setup) for RHEL 9 environments.

---

## Overview

```
┌──────────────────────────────────┐  USB / SCP / file share
│  BUILD MACHINE (internet)        │ ────────────────────────►  airgap-bundle-YYYY-MM-DD/
│  Any OS with Docker installed    │                            ├── images/dc-dr-images.tar.gz
│                                  │                            ├── config/dc-dr-config.tar.gz
│  bash build-airgap-bundle.sh     │                            ├── rpms/docker/   ← Docker CE RPMs
│                                  │                            ├── rpms/deps/     ← selinux etc.
│  Outputs a single self-contained │                            ├── pip-wheels/    ← podman-compose
│  bundle directory                │                            ├── tools/jq       ← static binary
└──────────────────────────────────┘                            └── install-scripts/ (1–6)

                                                         ┌───────────────────────────────┐
                                                         │  DC1 VM — RHEL 9 (airgap)    │
                                                         │  PostgreSQL primary (Patroni) │
                                                         │  MinIO DC1                    │
                                                         │  Prometheus + Grafana         │
                                                         └───────────────────────────────┘
                                                                      │ patroni-cluster
                                                                      │ Docker network
                                                         ┌───────────────────────────────┐
                                                         │  DC2 VM — RHEL 9 (airgap)    │
                                                         │  PostgreSQL replica (Patroni) │
                                                         │  MinIO DC2                    │
                                                         │  Patroni Raft witness         │
                                                         └───────────────────────────────┘
```

The complete DC/DR stack consists of:

| Component | DC1 VM | DC2 VM |
|---|---|---|
| PostgreSQL | Primary (Patroni leader) | Replica (streaming) |
| Patroni Raft | Voter | Voter + Witness |
| MinIO | DC1 instance | DC2 instance |
| Monitoring | Prometheus + Grafana + Alertmanager | — |
| postgres_exporter | Yes | — |

---

## Part A — Build Machine (Internet-Connected, Any OS)

### A1. Prerequisites

| Requirement | Version | Check |
|---|---|---|
| Docker Engine | 24.0+ | `docker version` |
| Docker Compose plugin | v2.x | `docker compose version` |
| Internet access | — | `curl https://registry-1.docker.io` |
| Python 3 | 3.8+ | `python3 --version` |
| Free disk space | ≥ 15 GB | `df -h .` |

> **Corporate proxy (Zscaler / Netskope / SSL inspection):**  
> Set `HTTPS_PROXY` and ensure Docker is configured to use the proxy.  
> All `pip download` commands in the Dockerfiles already include `--trusted-host` flags.
> For Docker builds add `--build-arg HTTPS_PROXY=$HTTPS_PROXY`.

### A2. Clone the repository

```bash
git clone <your-internal-git-url>/image-kayaking.git
cd image-kayaking
```

### A3. Build the Patroni image

The Patroni image must be built — it is not available on Docker Hub.

```bash
cd dc-dr-setup

docker build \
  --no-cache \
  -t local/patroni:3.3.0 \
  -f patroni/Dockerfile \
  patroni/

# Verify
docker run --rm local/patroni:3.3.0 patroni --version
# Expected: patroni 3.3.0
```

### A4. Pull all upstream images

```bash
docker pull postgres:16-bookworm
docker pull minio/minio:RELEASE.2025-05-24T17-08-30Z
docker pull minio/mc:RELEASE.2024-11-17T19-35-25Z
docker pull prom/prometheus:v2.52.0
docker pull prom/alertmanager:v0.27.0
docker pull grafana/grafana-oss:11.0.0
docker pull prometheuscommunity/postgres-exporter:v0.15.0

# Verify all 8 images are present
docker images | grep -E 'patroni|minio|prometheus|alertmanager|grafana|postgres-exporter'
# Expected: 8 lines
```

### A5. Run the bundle builder

```bash
cd image-kayaking  # repo root
bash dc-dr-setup/scripts/build-airgap-bundle.sh
```

The script runs 8 steps automatically:

| Step | What it does | Time |
|---|---|---|
| 1 | Verifies all 8 images exist locally | < 5 s |
| 2 | Creates bundle directory structure | < 1 s |
| 3 | Saves all Docker images to `dc-dr-images.tar.gz` | 5–15 min |
| 4 | Downloads Docker CE RPMs for RHEL 9 (via CentOS Stream 9 container) | 2–5 min |
| 5 | Downloads podman-compose pip wheels | 1–2 min |
| 6 | Downloads `jq` static binary | < 30 s |
| 7 | Packages all config files + generates 6 install scripts | < 30 s |
| 8 | Generates SHA256 manifest | < 30 s |

Output: `airgap-bundle-YYYY-MM-DD/` in the repo root (~4–8 GB total).

### A6. Verify the bundle

```bash
ls -lh airgap-bundle-*/
# Should contain:
#   README-FIRST.txt
#   BUNDLE-MANIFEST.txt
#   images/dc-dr-images.tar.gz     (3–5 GB)
#   config/dc-dr-config.tar.gz     (~100 KB)
#   rpms/docker/*.rpm              (Docker CE packages)
#   rpms/deps/*.rpm                (container-selinux etc.)
#   pip-wheels/podman-compose/     (.whl files)
#   tools/jq                       (static binary)
#   install-scripts/               (01-06 scripts)

# Spot-check checksums
cat airgap-bundle-*/BUNDLE-MANIFEST.txt | grep -A50 "SHA256 CHECKSUMS"
```

### A7. Transfer to airgap VMs

```bash
# Transfer to DC1
scp -r airgap-bundle-YYYY-MM-DD/ user@dc1-vm:/opt/dc-dr-bundle/

# Transfer to DC2 (same bundle — used on both VMs)
scp -r airgap-bundle-YYYY-MM-DD/ user@dc2-vm:/opt/dc-dr-bundle/
```

For USB transfer:
```bash
cp -r airgap-bundle-YYYY-MM-DD/ /media/usb/dc-dr-bundle/
# sync and unmount
sync && umount /media/usb
```

---

## Part B — RHEL 9 VM Prerequisites

Perform these steps on **both DC1 and DC2 VMs** before running any install scripts.

### B1. Firewall — open required ports

Ports that must be reachable **between DC1 and DC2**:

```bash
# On DC1 — allow inbound from DC2
sudo firewall-cmd --permanent --add-port=5010/tcp   # Patroni Raft peer
sudo firewall-cmd --permanent --add-port=8008/tcp   # Patroni REST API
sudo firewall-cmd --permanent --add-port=9000/tcp   # MinIO S3 API

# On DC2 — same
sudo firewall-cmd --permanent --add-port=5010/tcp
sudo firewall-cmd --permanent --add-port=8008/tcp
sudo firewall-cmd --permanent --add-port=9000/tcp

# Apply on both VMs
sudo firewall-cmd --reload
```

Ports only needed on DC1 (admin/monitoring):

```bash
sudo firewall-cmd --permanent --add-port=3001/tcp   # Grafana UI
sudo firewall-cmd --permanent --add-port=9090/tcp   # Prometheus
sudo firewall-cmd --permanent --add-port=9093/tcp   # Alertmanager
sudo firewall-cmd --permanent --add-port=5432/tcp   # PostgreSQL (pgAdmin access)
sudo firewall-cmd --permanent --add-port=9001/tcp   # MinIO console
sudo firewall-cmd --reload
```

> **Note on ports:** In local-test mode (single VM), DC2 uses offset ports:
> 5433/8009/9002/9003. Adjust firewall rules accordingly.

### B2. SELinux — allow Docker container network

```bash
# Required for Docker containers to communicate over the network
sudo setsebool -P container_manage_cgroup 1

# If using Podman with rootless mode
sudo setsebool -P allow_execmem 1
```

### B3. Disk space check

```bash
df -h /opt /home /var/lib/docker 2>/dev/null
# Minimum:
#   /opt or install location: 5 GB (for images + data)
#   /var/lib/docker: 10 GB (Docker image and volume storage)
```

If `/var/lib/docker` doesn't have enough space, configure Docker to use a different location:

```bash
# Edit Docker daemon config BEFORE loading images
sudo mkdir -p /etc/docker
cat | sudo tee /etc/docker/daemon.json << 'EOF'
{
  "data-root": "/data/docker"
}
EOF
sudo systemctl restart docker
```

### B4. Verify network connectivity between VMs

```bash
# From DC1, verify DC2 is reachable on required ports
nc -zv <DC2_IP> 5010  && echo "Raft port OK"
nc -zv <DC2_IP> 8008  && echo "Patroni API OK"
nc -zv <DC2_IP> 9000  && echo "MinIO port OK"

# From DC2, verify DC1 is reachable
nc -zv <DC1_IP> 5010
nc -zv <DC1_IP> 8008
nc -zv <DC1_IP> 9000
```

> If `nc` is not available: `sudo dnf install -y ncat` (from RHEL BaseOS/AppStream).

---

## Part C — Install Container Runtime (Choose One)

### Option A — Docker CE (Recommended if Docker experience)

Run on **both VMs**:

```bash
cd /opt/dc-dr-bundle/install-scripts
sudo bash 01-install-docker-rhel9.sh
```

The script:
1. Removes old Docker versions (if any)
2. Installs dependency RPMs (`container-selinux`, `libcgroup`, etc.)
3. Installs Docker CE, Docker CLI, Compose plugin, BuildX plugin
4. Enables and starts the `docker` systemd service
5. Adds the current user to the `docker` group

After install, verify:

```bash
docker --version
# Docker version 27.x.x, build ...

docker compose version
# Docker Compose version v2.x.x

# Test without sudo (after newgrp or re-login)
newgrp docker
docker info | grep -E "Server Version|Storage Driver"
```

**If RPM download failed during bundle build** (no RPMs in `rpms/docker/`):

On a RHEL 9 / CentOS Stream 9 machine with internet access:

```bash
# Option 1: Use a CentOS Stream 9 machine or VM
sudo dnf config-manager \
  --add-repo https://download.docker.com/linux/centos/docker-ce.repo
dnf download --resolve --alldeps --arch=x86_64 \
  --destdir=./docker-rpms \
  docker-ce docker-ce-cli containerd.io \
  docker-compose-plugin docker-buildx-plugin
# Copy docker-rpms/ to the airgap VM and:
sudo dnf localinstall -y --disablerepo='*' ./docker-rpms/*.rpm
```

### Option B — Podman (Native RHEL 9, Zero Extra RPMs)

Podman is included in RHEL 9 BaseOS — it is either pre-installed or available
from the RHEL 9 installation media without any subscriptions or internet.

**Check if already installed:**

```bash
podman --version
# podman version 4.x.x
```

**If not installed (install from RHEL 9 BaseOS):**

```bash
# From local Satellite / RHEL 9 BaseOS repo
sudo dnf install -y podman

# OR from RHEL 9 ISO media (no subscription required):
sudo dnf install -y --disablerepo='*' \
  --enablerepo='BaseOS,AppStream' podman
```

**Install podman-compose from bundled pip wheels:**

```bash
cd /opt/dc-dr-bundle/install-scripts
sudo bash 02-install-podman-compose.sh
```

**Verify:**

```bash
podman --version
podman-compose --version
```

**Podman compatibility note:**  
The DC/DR compose files use Docker Compose syntax. With Podman:
- Replace `docker compose` with `podman-compose` in all commands
- Replace `docker` with `podman` for `docker exec`, `docker logs`, etc.
- Or create shell aliases:

```bash
# Add to ~/.bashrc
alias docker='podman'
alias 'docker compose'='podman-compose'
```

---

## Part D — Load Docker Images

Run on **both VMs** (after installing Docker or Podman):

```bash
cd /opt/dc-dr-bundle/install-scripts
bash 03-load-images.sh
```

The script auto-detects whether to use `docker` or `podman`, then loads
all 8 images from `images/dc-dr-images.tar.gz`.

Verify images are loaded:

```bash
docker images | grep -E 'patroni|minio|prometheus|grafana|postgres-exporter|alertmanager'
# Expected: 8 lines
```

---

## Part E — Install Convenience Tools

### E1. jq (JSON processor)

The `jq` binary is included as a static binary — no install needed:

```bash
# Install to path
sudo cp /opt/dc-dr-bundle/tools/jq /usr/local/bin/jq
sudo chmod +x /usr/local/bin/jq

# Verify
jq --version
# jq-1.7.1
```

### E2. mc (MinIO Client)

`mc` is included as a Docker image (`minio/mc`). Use it via a wrapper script:

```bash
# Create mc wrapper (already set up by setup-airgap.sh if you used it)
cat | sudo tee /usr/local/bin/mc << 'EOF'
#!/bin/bash
docker run --rm -i \
  --network host \
  -v "$HOME/.mc:/root/.mc" \
  minio/mc:RELEASE.2024-11-17T19-35-25Z "$@"
EOF
sudo chmod +x /usr/local/bin/mc

# Test
mc --version
```

---

## Part F — Configure and Deploy

### F1. Generate strong passwords

Before editing `.env`, generate passwords on the DC1 VM:

```bash
echo "PATRONI_SUPERUSER_PASSWORD=$(openssl rand -base64 24)"
echo "PATRONI_REPLICATION_PASSWORD=$(openssl rand -base64 24)"
echo "MINIO_ROOT_PASSWORD=$(openssl rand -base64 24)"
```

Save these — you will need the same values on both VMs.

### F2. Deploy DC1 stack

```bash
cd /opt/dc-dr-bundle/install-scripts
bash 04-deploy-dc1.sh
```

This script:
1. Extracts `dc-dr-config.tar.gz` to `~/dc-dr/dc-dr-setup/`
2. Prompts you to edit `.env` (DC1_IP, DC2_IP, passwords)
3. Asks deployment mode (local-test or two-VM)
4. Runs `docker compose -p dc1 -f docker-compose.dc1.yml up -d`
5. Waits 40 seconds for PostgreSQL to bootstrap
6. Runs health checks and reports status

**Manual alternative (if you prefer direct control):**

```bash
mkdir -p ~/dc-dr
tar -xzf /opt/dc-dr-bundle/config/dc-dr-config.tar.gz -C ~/dc-dr

cd ~/dc-dr/dc-dr-setup
cp .env.example .env
vi .env   # Set DC1_IP, DC2_IP, passwords

docker compose -p dc1 -f docker-compose.dc1.yml --env-file .env up -d
```

**Check DC1 is healthy (wait 40 seconds first):**

```bash
# Patroni leader
curl -s http://localhost:8008/leader
# Expected: "pg-dc1"

# Cluster state
curl -s http://localhost:8008/cluster | python3 -m json.tool

# PostgreSQL
docker exec postgres-dc1 psql -U postgres -c "SELECT version();"

# MinIO
curl -s http://localhost:9000/minio/health/live && echo "MinIO OK"

# Prometheus (allow 60s to start scraping)
curl -s http://localhost:9090/api/v1/targets | \
  python3 -c "import json,sys; [print(t['labels']['job'], t['health']) \
  for t in json.load(sys.stdin)['data']['activeTargets']]"
```

### F3. Deploy DC2 stack

**Two-VM mode** (DC2 on its own VM):

```bash
# On DC2 VM — after loading images (steps D–E above):
cd /opt/dc-dr-bundle/install-scripts
bash 05-deploy-dc2.sh   # select mode 2
```

**Local-test mode** (DC2 on same machine as DC1):

```bash
# On DC1 VM:
bash 05-deploy-dc2.sh   # select mode 1
```

Wait 60–90 seconds for DC2 to complete `pg_basebackup` from DC1.

**Check DC2 is streaming:**

```bash
# From DC1 or DC2
curl -s http://localhost:8008/cluster | python3 -m json.tool
```

Expected output:

```json
{
  "members": [
    { "name": "pg-dc1",     "role": "Leader",  "state": "running",   "lag": "" },
    { "name": "pg-dc2",     "role": "Replica", "state": "streaming", "lag": "0" },
    { "name": "pg-witness", "role": "Replica", "state": "streaming", "lag": "0" }
  ]
}
```

### F4. Wire MinIO site replication

Run **once**, from DC1, after both MinIO instances are healthy:

```bash
cd /opt/dc-dr-bundle/install-scripts
bash 06-setup-minio-replication.sh
```

Or manually:

```bash
cd ~/dc-dr/dc-dr-setup
source .env
bash scripts/setup-minio-replication.sh
```

Verify replication is active:

```bash
mc admin replicate info minio-dc1
# Expected: Site Replication Enabled: true
# Expected: dc1 — online, dc2 — online
```

---

## Part G — Monitoring Setup

Grafana, Prometheus, and Alertmanager start automatically with the DC1 stack.

### Access URLs (two-VM production)

| Service | URL | Credentials |
|---|---|---|
| Grafana | `http://<DC1_IP>:3001` | admin / admin |
| Prometheus | `http://<DC1_IP>:9090` | — |
| Alertmanager | `http://<DC1_IP>:9093` | — |
| MinIO DC1 console | `http://<DC1_IP>:9001` | MINIO_ROOT_USER / MINIO_ROOT_PASSWORD |
| MinIO DC2 console | `http://<DC2_IP>:9001` | same credentials |
| PostgreSQL DC1 | `<DC1_IP>:5432` | postgres / PATRONI_SUPERUSER_PASSWORD |
| PostgreSQL DC2 | `<DC2_IP>:5432` | postgres / PATRONI_SUPERUSER_PASSWORD |

> **Grafana first login:** Change the admin password immediately after first login.

### Grafana dashboards

Two dashboards are pre-provisioned:

1. **Patroni HA — PostgreSQL DC/DR** — cluster overview, replication lag,
   WAL positions, node roles, DCS state
2. **MinIO DC/DR Site Replication** — site health, storage capacity, object
   counts, replication bytes, S3 API traffic

Both dashboards populate automatically within 2–3 Prometheus scrape cycles
(~30–45 seconds after the stack starts).

### Check all Prometheus targets are UP

```bash
curl -s http://localhost:9090/api/v1/targets | \
  python3 -c "
import json, sys
data = json.load(sys.stdin)
for t in data['data']['activeTargets']:
    print(f\"  {t['labels']['job']:<20} {t['labels'].get('instance','?'):<30} {t['health']}\")
"
```

Expected: 7 targets all showing `up`:

```
  patroni              postgres-dc1:8008              up
  patroni-dc2          postgres-dc2:8008              up
  patroni-witness      postgres-witness:8008          up
  postgres             postgres-exporter:9187         up
  minio-dc1            minio-dc1:9000                 up
  minio-dc2            minio-dc2:9000                 up
  prometheus           localhost:9090                 up
```

---

## Part H — Final Go/No-Go Checklist

Run through every item before signing off on the deployment:

```
INFRASTRUCTURE
[ ] Both VMs online and reachable from each other
[ ] Firewall ports 5010, 8008, 9000 open between DC1 and DC2
[ ] Docker or Podman installed on both VMs (docker --version)
[ ] All 8 images loaded on both VMs (docker images | wc -l → ≥ 8)

POSTGRESQL HA
[ ] curl http://<DC1_IP>:8008/leader  → "pg-dc1"
[ ] curl http://<DC1_IP>:8008/cluster → 3 members: Leader + 2 Replicas
[ ] pg-dc2 state: streaming, lag: 0
[ ] pg-witness state: streaming, lag: 0
[ ] Write to DC1:5432, read from DC2:5432 → data visible

FAILOVER TEST (smoke test only — optional pre-prod)
[ ] docker stop postgres-dc1  →  DC2 promotes within 40 seconds
[ ] docker start postgres-dc1  →  DC1 rejoins as replica, lag=0

MINIO DR
[ ] mc admin replicate info minio-dc1 → replication enabled, dc2 online
[ ] mc cp <file> minio-dc1/test-bucket/ → appears on minio-dc2 within 5s

MONITORING
[ ] Grafana at http://<DC1_IP>:3001 — both dashboards show data
[ ] Prometheus: all 7 targets UP (http://<DC1_IP>:9090/targets)
[ ] Alertmanager UI loads at http://<DC1_IP>:9093
[ ] No alerts firing in healthy state

SECURITY
[ ] .env file permissions: chmod 600 ~/dc-dr/dc-dr-setup/.env
[ ] Grafana admin password changed from default
[ ] PostgreSQL pg_hba.conf allows only known IPs (review if needed)
[ ] MinIO console not exposed to untrusted networks
```

---

## Troubleshooting

### Docker CE install fails — missing container-selinux

**Symptom:**
```
Error: nothing provides container-selinux needed by docker-ce-...
```

**Fix:**
```bash
# container-selinux is in RHEL 9 AppStream (not in Docker's repo)
# Install from bundled deps RPMs:
sudo dnf localinstall -y --disablerepo='*' /opt/dc-dr-bundle/rpms/deps/*.rpm

# Then retry Docker CE install:
sudo dnf localinstall -y --disablerepo='*' /opt/dc-dr-bundle/rpms/docker/*.rpm
```

If the deps RPMs weren't bundled, fetch `container-selinux` from your RHEL Satellite
or install Podman (Option B) which already includes it.

---

### DC2 not streaming — timeline mismatch

**Symptom:**
```
FATAL: requested timeline X does not exist on this server
```
or
```
ERROR: replication slot "pg_dc2" does not exist
```

**Cause:** DC2 has stale data volumes from a previous run at a different timeline.

**Fix:**
```bash
# On DC1:
docker compose -p dc1 -f docker-compose.dc1.yml --env-file .env down -v
# On DC2 (or DC1 for local-test):
docker compose -p dc2 -f docker-compose.dc2-local.yml --env-file .env down -v

# Then restart both from scratch:
bash 04-deploy-dc1.sh
bash 05-deploy-dc2.sh
```

> **Rule:** Always use `down -v` when restarting from scratch. PostgreSQL
> stores the WAL timeline in the data volume. A DC2 volume at timeline 1
> cannot stream from a DC1 at timeline 3.

---

### MinIO replication fails — connection refused

**Symptom:**
```
mc: ERROR Unable to initialize new site replication ... connection refused
```

**Cause:** MinIO containers can't reach each other by container name. This
happens when they are on separate Docker networks.

**Fix:**
```bash
# The setup-minio-replication.sh script handles this automatically.
# If running manually:
docker network connect patroni-cluster minio-dc1 2>/dev/null || true
docker network connect patroni-cluster minio-dc2 2>/dev/null || true
```

---

### Prometheus shows targets as DOWN

**Symptom:** One or more targets show `down` in Prometheus UI.

**Check:**
```bash
# Check postgres-exporter can reach PostgreSQL
docker logs postgres-exporter | tail -20

# Check Patroni is reachable
curl -s http://localhost:8008/metrics | head -5

# Check MinIO metrics endpoint
curl -s http://localhost:9000/minio/v2/metrics/cluster | head -5
```

**Common fixes:**
- `postgres-exporter` down → check `PATRONI_SUPERUSER_PASSWORD` in `.env` matches running PG
- `patroni-dc2` down → DC2 not started or firewall blocking port 8008
- `minio-dc2` down → DC2 MinIO not started

---

### Grafana shows "No data" on panels

**Symptom:** Dashboard panels show "No data" or "N/A".

**Cause:** All metric names in the dashboards use the correct names verified
against this stack. If you see "No data", the issue is almost always that
Prometheus can't scrape the target.

**Diagnosis:**
```bash
# Check Prometheus targets
curl -s http://localhost:9090/api/v1/targets | \
  python3 -c "import json,sys; \
  [print(t['labels']['job'], t['health'], t.get('lastError','')) \
  for t in json.load(sys.stdin)['data']['activeTargets']]"

# Check specific metric exists
curl -s http://localhost:9090/api/v1/query?query=patroni_master | \
  python3 -m json.tool | grep -A5 '"result"'
```

---

### Patroni Raft quorum lost

**Symptom:** `curl http://localhost:8008/cluster` returns `{"detail":"Cluster not found"}`
or Patroni logs show `not enough voters`.

**Cause:** At least 2 of 3 Raft voters (DC1, DC2, witness) must be running.

**Fix:**
```bash
# Check which nodes are up
docker ps --filter name=postgres

# If witness is down:
docker compose -p dc2 -f docker-compose.dc2-local.yml --env-file .env start postgres-witness

# If DC1 is down:
docker compose -p dc1 -f docker-compose.dc1.yml --env-file .env start postgres-dc1
```

---

## Appendix — Bundle Contents Reference

### Docker images included

| Image | Purpose | Size (approx) |
|---|---|---|
| `local/patroni:3.3.0` | PostgreSQL 16 + Patroni 3.3.0 + Raft DCS | ~400 MB |
| `postgres:16-bookworm` | Base PostgreSQL (used by Patroni image) | ~430 MB |
| `minio/minio:RELEASE.2025-05-24T17-08-30Z` | Object storage (S3-compatible) | ~170 MB |
| `minio/mc:RELEASE.2024-11-17T19-35-25Z` | MinIO Client (for replication setup) | ~50 MB |
| `prom/prometheus:v2.52.0` | Metrics collection and alerting rules | ~250 MB |
| `prom/alertmanager:v0.27.0` | Alert routing and notifications | ~60 MB |
| `grafana/grafana-oss:11.0.0` | Visualization dashboards | ~380 MB |
| `prometheuscommunity/postgres-exporter:v0.15.0` | PostgreSQL metrics exporter | ~40 MB |

**Total uncompressed:** ~1.8 GB  
**Total in `dc-dr-images.tar.gz`:** ~1.1–1.4 GB compressed

### RPM packages (Docker CE)

| Package | Purpose |
|---|---|
| `docker-ce` | Docker Engine |
| `docker-ce-cli` | Docker CLI |
| `containerd.io` | Container runtime |
| `docker-compose-plugin` | `docker compose` subcommand |
| `docker-buildx-plugin` | Multi-platform build support |
| `container-selinux` | SELinux policy for containers |
| `libcgroup` | Control group library (dependency) |
| `fuse-overlayfs` | Overlay filesystem (dependency) |

### Port reference (two-VM production)

| Port | Protocol | Direction | Purpose |
|---|---|---|---|
| 5432 | TCP | DC1↔DC2, clients | PostgreSQL |
| 5010 | TCP | DC1↔DC2 | Patroni Raft peer |
| 8008 | TCP | DC1↔DC2, monitoring | Patroni REST API |
| 9000 | TCP | DC1↔DC2, clients | MinIO S3 API |
| 9001 | TCP | Clients (admin) | MinIO console |
| 9090 | TCP | Admin | Prometheus |
| 9093 | TCP | Admin | Alertmanager |
| 3001 | TCP | Admin | Grafana |

### Port reference (local-test, single VM)

| Service | Host Port |
|---|---|
| PostgreSQL DC1 | 5432 |
| PostgreSQL DC2 | 5433 |
| PostgreSQL Witness | 5434 |
| Patroni API DC1 | 8008 |
| Patroni API DC2 | 8009 |
| Patroni API Witness | 8010 |
| MinIO DC1 API | 9000 |
| MinIO DC1 Console | 9001 |
| MinIO DC2 API | 9002 |
| MinIO DC2 Console | 9003 |
| Prometheus | 9090 |
| Alertmanager | 9093 |
| Grafana | 3001 |

---

## Appendix — Docker vs Podman Decision Guide

| Criterion | Docker CE | Podman |
|---|---|---|
| Available on RHEL 9 out-of-box | No (needs extra RPMs) | Yes (in BaseOS) |
| docker compose syntax | Native | Via podman-compose |
| Requires daemon (root) | Yes | No (rootless capable) |
| Red Hat supported | No | Yes (included in support) |
| Docker Hub compatibility | Native | Compatible |
| Best for | Teams with Docker experience | Native RHEL 9 deployments |

**Recommendation for airgap RHEL 9:**  
If your team is familiar with Docker and you have the RPMs in the bundle, use
Docker CE (Option A). If you want zero-dependency native RHEL 9 support, use
Podman (Option B) — it is fully compatible with the DC/DR compose files via
podman-compose.
