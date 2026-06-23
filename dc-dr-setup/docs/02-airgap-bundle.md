# Airgap Bundle — Build & Ship Guide

Build everything on an internet-connected machine, tar it up, and carry it
into the airgap environment on a USB drive or internal file transfer.

---

## 1. Prerequisites on the Build Machine

- Docker 24+ with BuildKit enabled
- `docker save` / `docker load` available
- `git` — to clone this repo
- Internet access (even through a corporate proxy — see proxy note below)

### Corporate proxy / SSL inspection note

If your proxy intercepts HTTPS (Zscaler, Netskope, etc.) add these flags to
every `pip download` call in the Dockerfile:

```
--trusted-host pypi.org \
--trusted-host files.pythonhosted.org \
--trusted-host pypi.python.org
```

These are already present in `patroni/Dockerfile`. No changes needed.

---

## 2. Build the Patroni Image

```bash
cd dc-dr-setup

docker build \
  --no-cache \
  -t local/patroni:3.3.0 \
  -f patroni/Dockerfile \
  patroni/
```

Verify the build:

```bash
docker run --rm local/patroni:3.3.0 patroni --version
# patroni 3.3.0
```

---

## 3. Pull all other images

```bash
docker pull postgres:16-bookworm
docker pull minio/minio:RELEASE.2025-05-24T17-08-30Z
docker pull prom/prometheus:v2.52.0
docker pull prom/alertmanager:v0.27.0
docker pull grafana/grafana-oss:11.0.0
docker pull prometheuscommunity/postgres-exporter:v0.15.0
```

Also pull the MinIO Client for site-replication wiring:

```bash
docker pull minio/mc:RELEASE.2024-11-17T19-35-25Z
```

---

## 4. Save all images to a tar bundle

```bash
mkdir -p airgap-bundle/images

docker save \
  local/patroni:3.3.0 \
  minio/minio:RELEASE.2025-05-24T17-08-30Z \
  prom/prometheus:v2.52.0 \
  prom/alertmanager:v0.27.0 \
  grafana/grafana-oss:11.0.0 \
  prometheuscommunity/postgres-exporter:v0.15.0 \
  minio/mc:RELEASE.2024-11-17T19-35-25Z \
  | gzip > airgap-bundle/images/dc-dr-images.tar.gz

# Check size
ls -lh airgap-bundle/images/dc-dr-images.tar.gz
```

Typical size: ~2–3 GB compressed.

---

## 5. Bundle the repo config files

```bash
# From the repo root
tar -czf airgap-bundle/dc-dr-config.tar.gz \
  dc-dr-setup/docker-compose.dc1.yml \
  dc-dr-setup/docker-compose.dc2-local.yml \
  dc-dr-setup/docker-compose.dc2.yml \
  dc-dr-setup/.env.example \
  dc-dr-setup/patroni/ \
  dc-dr-setup/postgres/ \
  dc-dr-setup/minio/ \
  dc-dr-setup/monitoring/ \
  dc-dr-setup/scripts/ \
  dc-dr-setup/docs/
```

---

## 6. Copy to USB / transfer medium

```bash
# Final bundle contents
ls -lh airgap-bundle/
# images/dc-dr-images.tar.gz   ~2-3 GB
# dc-dr-config.tar.gz          ~50 KB
```

Copy both files to USB or internal file share.

---

## 7. On the airgap DC1 VM — load images

```bash
# Copy files from USB
cp /media/usb/images/dc-dr-images.tar.gz /opt/dc-dr/
cp /media/usb/dc-dr-config.tar.gz /opt/dc-dr/

cd /opt/dc-dr

# Load all images into Docker
gunzip -c images/dc-dr-images.tar.gz | docker load

# Verify
docker images | grep -E 'patroni|minio|prometheus|grafana|postgres-exporter'
```

---

## 8. Extract config files

```bash
cd /opt/dc-dr
tar -xzf dc-dr-config.tar.gz
ls dc-dr-setup/
```

---

## 9. Prepare the .env file

```bash
cp dc-dr-setup/.env.example dc-dr-setup/.env
# Edit with actual values
vi dc-dr-setup/.env
```

Minimum required values:

```env
DC1_IP=<DC1 host IP or 127.0.0.1 for local test>
DC2_IP=<DC2 host IP or same as DC1_IP for local test>
PATRONI_SUPERUSER_PASSWORD=<strong password>
PATRONI_REPLICATION_PASSWORD=<strong password>
MINIO_ROOT_USER=minioadmin
MINIO_ROOT_PASSWORD=<strong password>
```

---

## 10. Repeat on DC2 VM

Repeat steps 7–9 on the DC2 VM. The same image bundle is used on both VMs.
DC2 uses `docker-compose.dc2-local.yml` (same VM) or `docker-compose.dc2.yml`
(separate VM — update DC2_IP accordingly).

---

## Bundle Verification Checklist

```
[ ] docker images shows all 7 images on DC1
[ ] docker images shows all 7 images on DC2
[ ] .env file has correct IPs and passwords on both VMs
[ ] patroni-cluster Docker network does NOT exist yet (will be created by DC1 compose)
[ ] Ports 5432, 8008, 5010 are open/reachable between DC1 and DC2
[ ] Port 9000 is open between DC1 and DC2 (MinIO site replication)
```
