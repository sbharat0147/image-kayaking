#!/usr/bin/env bash
# Sets up MinIO site replication between DC1 and DC2.
# Run ONCE after both stacks are up and healthy.
# Safe to re-run — idempotent.
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

echo "==> Waiting for DC1 MinIO to be ready..."
until curl -sf "${DC1_URL}/minio/health/live" > /dev/null; do sleep 2; done
echo "    DC1 OK"

echo "==> Waiting for DC2 MinIO to be ready..."
until curl -sf "${DC2_URL}/minio/health/live" > /dev/null; do sleep 2; done
echo "    DC2 OK"

# Run all mc commands in a single container so aliases persist across commands.
docker run --rm --network host minio/mc:latest /bin/sh -c "
  set -e
  mc alias set minio-dc1 ${DC1_URL} ${MINIO_USER} ${MINIO_PASS} --no-color
  mc alias set minio-dc2 ${DC2_URL} ${MINIO_USER} ${MINIO_PASS} --no-color

  if mc admin replicate info minio-dc1 --no-color 2>/dev/null | grep -q 'Site Name'; then
    echo 'Site replication already configured.'
    mc admin replicate info minio-dc1 --no-color
    exit 0
  fi

  echo 'Enabling site replication DC1 <-> DC2...'
  mc admin replicate add minio-dc1 minio-dc2 --no-color

  echo 'Verifying...'
  mc admin replicate info minio-dc1 --no-color
"

echo ""
echo "Done. MinIO site replication is active."
