#!/usr/bin/env bash
# Sets up MinIO site replication between DC1 and DC2.
# Run ONCE after both stacks are up and healthy.
# Safe to re-run — idempotent.
#
# Requires both MinIO containers to be on the patroni-cluster network
# so DC1's MinIO server can reach DC2 by container name for peer verification.
set -euo pipefail

ENV_FILE="${1:-.env.local}"
if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: env file '$ENV_FILE' not found. Run from dc-dr-setup/ directory."
  exit 1
fi

# Load env
set -a; source "$ENV_FILE"; set +a

DC1_URL="http://localhost:9000"
DC2_URL="http://localhost:9002"
MINIO_USER="${MINIO_ROOT_USER:-minioadmin}"
MINIO_PASS="${MINIO_ROOT_PASSWORD:-minioadmin}"

# Container-network URLs — reachable from inside DC1's MinIO container.
DC1_INTERNAL="http://minio-dc1:9000"
DC2_INTERNAL="http://minio-dc2:9000"

# mc uses MC_HOST_<alias> env vars as aliases — no alias set command needed.
MC="docker run --rm --network patroni-cluster \
  -e MC_HOST_minio-dc1=http://${MINIO_USER}:${MINIO_PASS}@minio-dc1:9000 \
  -e MC_HOST_minio-dc2=http://${MINIO_USER}:${MINIO_PASS}@minio-dc2:9000 \
  minio/mc:latest --no-color"

echo "==> Waiting for DC1 MinIO to be ready..."
until curl -sf "${DC1_URL}/minio/health/live" > /dev/null; do sleep 2; done
echo "    DC1 OK"

echo "==> Waiting for DC2 MinIO to be ready..."
until curl -sf "${DC2_URL}/minio/health/live" > /dev/null; do sleep 2; done
echo "    DC2 OK"

echo "==> Ensuring both MinIO containers are on patroni-cluster network..."
docker network connect patroni-cluster minio-dc1 2>/dev/null && echo "    minio-dc1 connected" || echo "    minio-dc1 already on network"
docker network connect patroni-cluster minio-dc2 2>/dev/null && echo "    minio-dc2 connected" || echo "    minio-dc2 already on network"

echo "==> Checking existing replication status..."
if $MC admin replicate info minio-dc1 2>/dev/null | grep -q "Site Name"; then
  echo "    Site replication already configured."
  $MC admin replicate info minio-dc1
  exit 0
fi

echo "==> Enabling site replication DC1 <-> DC2..."
$MC admin replicate add minio-dc1 minio-dc2

echo "==> Verifying replication status..."
$MC admin replicate info minio-dc1

echo ""
echo "Done. MinIO site replication is active."
