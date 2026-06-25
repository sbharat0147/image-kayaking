# Developer Manual — Airgap Cluster Setup

**Audience:** Developer or DevOps engineer responsible for packaging and deploying
the DC/DR cluster on a network with no internet access.

**Goal:** Take a freshly cloned repo on an internet-connected build machine,
produce a self-contained bundle, transfer it to the airgap environment, and
bring up a fully working cluster — PostgreSQL HA, MinIO DC/DR, MCP Server,
and monitoring — without any outbound network calls.

---

## Overview

```
┌─────────────────────────────┐     USB / internal     ┌──────────────────────────────┐
│  BUILD MACHINE (internet)   │  ──── file transfer ──► │  AIRGAP DC1 VM               │
│                             │                          │                              │
│  git clone + docker build   │                          │  docker load + compose up    │
│  docker pull (all images)   │                          │  PostgreSQL leader           │
│  pip download (mcp wheels)  │                          │  MinIO DC1                   │
│  HF model download          │                          │  MCP Server                  │
│  tar → airgap-bundle.tar.gz │                          │  Prometheus + Grafana        │
└─────────────────────────────┘                          └──────────────────────────────┘
                                                                      │  patroni-cluster
                                                                      │  Docker network
                                                         ┌──────────────────────────────┐
                                                         │  AIRGAP DC2 VM (or same VM)  │
                                                         │                              │
                                                         │  PostgreSQL replica          │
                                                         │  MinIO DC2                   │
                                                         │  Patroni witness             │
                                                         └──────────────────────────────┘
```

---

## Part A — Build Machine (Internet-Connected)

### A1. Prerequisites

| Requirement | Minimum version | Check |
|---|---|---|
| Docker Engine | 24.0+ with BuildKit | `docker version` |
| Docker Compose plugin | v2.x | `docker compose version` |
| Python | 3.11+ | `python3 --version` |
| wget | any | `wget --version` |
| git | any | `git --version` |
| Free disk space | ≥ 15 GB | `df -h .` |

If your build machine uses a corporate SSL-inspection proxy (Zscaler, Netskope, etc.):

```bash
# Verify proxy env vars are set
echo $HTTPS_PROXY   # should be non-empty

# All Dockerfiles already include --trusted-host flags for pip.
# No extra configuration needed.
```

### A2. Clone the repository

```bash
git clone <your-internal-git-url>/image-kayaking.git
cd image-kayaking
```

### A3. Build the Patroni image

```bash
cd dc-dr-setup

docker build \
  --no-cache \
  -t local/patroni:3.3.0 \
  -f patroni/Dockerfile \
  patroni/

# Verify
docker run --rm local/patroni:3.3.0 patroni --version
# patroni 3.3.0
```

### A4. Build the MCP Server image

```bash
cd ../mcp-server

# Step 1: download the sentence-transformer embedding model
# (requires internet — run once, model is baked into the image)
bash scripts/download-model.sh

# Verify model downloaded successfully
ls -lh models/sentence-transformers_all-MiniLM-L6-v2/
# Should contain: config.json, tokenizer.json, model.safetensors (or pytorch_model.bin), etc.

# Step 2: build the image (no internet needed after this point)
docker build \
  --no-cache \
  -t local/mcp-server:1.0.0 \
  -f Dockerfile \
  .

# Verify
docker run --rm local/mcp-server:1.0.0 python3 -c \
  "from sentence_transformers import SentenceTransformer; print('OK')"
# OK

cd ../dc-dr-setup
```

### A5. Pull all upstream images

```bash
docker pull postgres:16-bookworm
docker pull minio/minio:RELEASE.2025-05-24T17-08-30Z
docker pull minio/mc:RELEASE.2024-11-17T19-35-25Z
docker pull prom/prometheus:v2.52.0
docker pull prom/alertmanager:v0.27.0
docker pull grafana/grafana-oss:11.0.0
docker pull prometheuscommunity/postgres-exporter:v0.15.0

# Verify all 9 images are present
docker images | grep -E 'patroni|mcp-server|minio|postgres|prometheus|alertmanager|grafana|postgres-exporter'
```

### A6. Pre-download Python wheels for the MCP Server

> Skip this step if you built the MCP Server image in A4 — wheels are already
> embedded in the image. Only needed if you want to rebuild from scratch on the
> airgap machine.

```bash
cd ../mcp-server
mkdir -p airgap-wheels

docker run --rm \
  -v "$(pwd)/airgap-wheels:/wheels" \
  python:3.11-slim-bookworm \
  pip download \
    --no-cache-dir \
    --trusted-host pypi.org \
    --trusted-host files.pythonhosted.org \
    --trusted-host pypi.python.org \
    -r requirements.txt \
    -d /wheels

ls -lh airgap-wheels/ | head -20

cd ../dc-dr-setup
```

### A7. Package the airgap bundle

```bash
# Run the bundling script from dc-dr-setup/
bash scripts/build-airgap-bundle.sh

# The script creates: airgap-bundle-<date>/
#   images/dc-dr-images.tar.gz   — all Docker images (~3-5 GB)
#   dc-dr-config.tar.gz          — all config files, scripts, docs
#   SHA256SUMS                   — checksums for verification
#   BUNDLE_MANIFEST.txt          — human-readable contents list
```

Verify the bundle:

```bash
ls -lh airgap-bundle-*/
# SHA256SUMS
# BUNDLE_MANIFEST.txt
# images/dc-dr-images.tar.gz
# dc-dr-config.tar.gz

# Spot-check checksums
sha256sum -c airgap-bundle-*/SHA256SUMS
```

### A8. Transfer the bundle

```bash
# Copy to USB
cp -r airgap-bundle-*/ /media/usb/dc-dr-bundle/

# Or scp to a jump host
scp -r airgap-bundle-*/ user@jumphost:/transfer/dc-dr-bundle/

# Or use internal file share
rsync -av airgap-bundle-*/ //fileserver/transfer/dc-dr-bundle/
```

---

## Part B — Airgap DC1 VM

### B1. Prerequisites on the airgap VM

| Requirement | Check |
|---|---|
| Docker Engine 24+ | `docker version` |
| Docker Compose plugin | `docker compose version` |
| Python 3.8+ (for verification only) | `python3 --version` |
| 20 GB free disk | `df -h /opt` |

Network ports that must be open **between DC1 and DC2**:

| Port | Protocol | Purpose |
|---|---|---|
| 5432 | TCP | PostgreSQL (optional — only if DC2 needs direct DB access) |
| 5010 | TCP | Patroni Raft peer communication |
| 8008 | TCP | Patroni REST API |
| 9000 | TCP | MinIO S3 API (site replication) |

### B2. Copy and verify the bundle

```bash
sudo mkdir -p /opt/dc-dr
sudo chown $USER /opt/dc-dr

# From USB
cp /media/usb/dc-dr-bundle/images/dc-dr-images.tar.gz /opt/dc-dr/
cp /media/usb/dc-dr-bundle/dc-dr-config.tar.gz /opt/dc-dr/
cp /media/usb/dc-dr-bundle/SHA256SUMS /opt/dc-dr/

cd /opt/dc-dr

# Verify checksums before loading anything
sha256sum -c SHA256SUMS
# Each file must show: OK
```

### B3. Load Docker images

```bash
cd /opt/dc-dr

gunzip -c images/dc-dr-images.tar.gz | docker load
# Loads all images — this takes 2–5 minutes

# Verify all images loaded
docker images | grep -E 'patroni|mcp-server|minio|postgres|prometheus|alertmanager|grafana|postgres-exporter'
# Expected: 9 images listed
```

### B4. Extract configuration files

```bash
cd /opt/dc-dr
tar -xzf dc-dr-config.tar.gz
ls dc-dr-setup/
```

### B5. Configure the environment file

```bash
cd /opt/dc-dr/dc-dr-setup
cp .env.example .env
```

Edit `.env` with the actual values for your environment:

```bash
vi .env
```

**Required values — do not leave as defaults:**

```env
# Network
DC1_IP=192.168.10.10      # IP of DC1 host (reachable from DC2)
DC2_IP=192.168.10.20      # IP of DC2 host (reachable from DC1)

# PostgreSQL
PATRONI_SUPERUSER_PASSWORD=<strong-random-password-min-20-chars>
PATRONI_REPLICATION_PASSWORD=<strong-random-password-min-20-chars>

# MinIO
MINIO_ROOT_USER=minioadmin
MINIO_ROOT_PASSWORD=<strong-random-password-min-20-chars>
```

> **Security note:** Generate passwords with `openssl rand -base64 24`

### B6. Start the DC1 stack

```bash
cd /opt/dc-dr/dc-dr-setup

docker compose -p dc1 \
  -f docker-compose.dc1.yml \
  --env-file .env \
  up -d
```

Watch startup logs:

```bash
docker compose -p dc1 -f docker-compose.dc1.yml logs -f postgres-patroni
# Wait for: "is_healthy: True" and "promoted self to leader"
```

### B7. Verify DC1 is healthy

```bash
# Wait ~30 seconds for PostgreSQL to initialise
sleep 30

# 1. Patroni leader
curl -s http://localhost:8008/leader
# Expected: "pg-dc1"

# 2. PostgreSQL accepting connections
docker exec postgres-dc1 \
  psql -U postgres -c "SELECT version();"
# Expected: PostgreSQL 16.x ...

# 3. MinIO healthy
curl -s http://localhost:9000/minio/health/live && echo "MinIO OK"

# 4. Prometheus targets (should be UP within 60s)
curl -s http://localhost:9090/api/v1/targets | \
  python3 -c "import sys,json; [print(t['labels']['job'], t['health']) for t in json.load(sys.stdin)['data']['activeTargets']]"

# 5. Grafana accessible
curl -s -o /dev/null -w "%{http_code}" http://localhost:3000
# Expected: 200
```

---

## Part C — Airgap DC2 VM

### C1. Copy the same bundle to DC2

Repeat **B2 through B5** on the DC2 VM using the same `airgap-bundle` files.
The same image tarball is used on both VMs.

The `.env` file must have the same passwords on both VMs but correct IPs:

```env
DC1_IP=192.168.10.10
DC2_IP=192.168.10.20
```

### C2. Start the DC2 stack

**Two-VM production mode** (DC2 is a separate host):

```bash
cd /opt/dc-dr/dc-dr-setup

docker compose -p dc2 \
  -f docker-compose.dc2.yml \
  --env-file .env \
  up -d
```

**Local-test mode** (both DCs on one machine — only for testing):

```bash
docker compose -p dc2 \
  -f docker-compose.dc2-local.yml \
  --env-file .env \
  up -d
```

### C3. Verify DC2 replica streaming

```bash
# Wait ~60s for pg_basebackup to complete
sleep 60

# Check cluster — from DC1 or DC2
curl -s http://${DC1_IP}:8008/cluster | python3 -m json.tool
```

Expected output:

```json
{
  "members": [
    { "name": "pg-dc1", "role": "Leader", "state": "running", "lag": "" },
    { "name": "pg-dc2", "role": "Replica", "state": "streaming", "lag": "0" },
    { "name": "pg-witness", "role": "Replica", "state": "streaming", "lag": "0" }
  ]
}
```

---

## Part D — Wire MinIO Site Replication

Run the following **once**, from either DC1 or DC2, after both MinIO instances
are healthy.

```bash
# Set aliases pointing to DC1 and DC2 MinIO
docker run --rm --network host \
  minio/mc:RELEASE.2024-11-17T19-35-25Z \
  alias set dc1 http://${DC1_IP}:9000 ${MINIO_ROOT_USER} ${MINIO_ROOT_PASSWORD}

docker run --rm --network host \
  minio/mc:RELEASE.2024-11-17T19-35-25Z \
  alias set dc2 http://${DC2_IP}:9000 ${MINIO_ROOT_USER} ${MINIO_ROOT_PASSWORD}

# Enable bidirectional site replication
docker run --rm --network host \
  minio/mc:RELEASE.2024-11-17T19-35-25Z \
  admin replicate add dc1 dc2

# Verify
docker run --rm --network host \
  minio/mc:RELEASE.2024-11-17T19-35-25Z \
  admin replicate info dc1
# Expected: "Site Replication Enabled: true"
```

---

## Part E — MCP Server (Optional)

The MCP Server is deployed separately from the DC/DR stack.

```bash
cd /opt/dc-dr/mcp-server

# Create .env
cat > .env <<EOF
OLLAMA_URL=http://<ollama-host-ip>:11434
OLLAMA_MODEL=<model-name-from-ollama-list>
API_KEY=<your-api-key>
LLM_DEFAULT_BACKEND=ollama
NO_PROXY=*
no_proxy=*
EOF

# Start (image already loaded from the bundle)
docker compose up -d

# Verify
curl -s -H "X-API-Key: <your-api-key>" http://localhost:8080/health
# Expected: {"status":"ok","tools_registered":<N>}
```

---

## Part F — Final Verification Checklist

Run through every item before signing off on the deployment.

```
POSTGRESQL HA
[ ] curl http://<DC1_IP>:8008/leader returns "pg-dc1"
[ ] curl http://<DC1_IP>:8008/cluster shows all 3 members (leader + 2 replicas)
[ ] DC2 replica lag = 0 (visible in cluster JSON)
[ ] Write to DC1 port 5432, read from DC2 port 5432 → data visible
[ ] DC2 is read-only (INSERT returns error)

FAILOVER
[ ] docker stop postgres-dc1
[ ] Within 30s: curl http://<DC2_IP>:8008/leader returns "pg-dc2"
[ ] docker start postgres-dc1  →  pg-dc1 rejoins as replica at lag=0

MINIO DC/DR
[ ] mc admin replicate info dc1 shows replication enabled
[ ] Create bucket + upload object on DC1 → visible on DC2 within 5s
[ ] Upload object on DC2 → visible on DC1 within 5s

MONITORING
[ ] http://<DC1_IP>:3000  Grafana loads (admin/admin)
[ ] "Patroni HA" dashboard shows green leader chip and lag=0
[ ] "MinIO DC/DR" dashboard shows both sites healthy
[ ] http://<DC1_IP>:9090/targets — all scrape targets green (UP)
[ ] http://<DC1_IP>:9093  Alertmanager UI loads

MCP SERVER (if deployed)
[ ] GET /health returns tools_registered > 0
[ ] POST /tools/execute with a known tool returns a result
[ ] POST /agent/run with a natural language query completes without error
```

---

## Troubleshooting Quick Reference

| Symptom | First check | Fix |
|---|---|---|
| Patroni stuck bootstrapping | `docker logs postgres-dc1 \| tail -30` | Check `.env` IPs are correct and DC2 ports reachable |
| DC2 not streaming | `docker logs postgres-dc2 \| grep -i error` | Ensure `patroni-cluster` network reachable or correct IPs in patroni.dc2.yml |
| MinIO replicate add fails | `curl http://<DC2_IP>:9000/minio/health/live` | Both MinIO must be healthy before wiring replication |
| Grafana shows no data | `http://<DC1_IP>:9090/targets` | Check postgres_exporter target is UP; verify `.env` password |
| MCP Server hits HF | `docker logs mcp-server \| grep huggingface` | Model dir missing — re-run `download-model.sh` and rebuild |

Full troubleshooting guide: [06-troubleshooting.md](06-troubleshooting.md)
