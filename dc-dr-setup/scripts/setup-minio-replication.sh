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
USER="${MINIO_ROOT_USER:-minioadmin}"
PASS="${MINIO_ROOT_PASSWORD:-minioadmin}"

MC="docker run --rm --network host minio/mc:latest"

echo "==> Waiting for DC1 MinIO to be ready..."
until curl -sf "${DC1_URL}/minio/health/live" > /dev/null; do sleep 2; done
echo "    DC1 OK"

echo "==> Waiting for DC2 MinIO to be ready..."
until curl -sf "${DC2_URL}/minio/health/live" > /dev/null; do sleep 2; done
echo "    DC2 OK"

echo "==> Setting aliases..."
$MC alias set minio-dc1 "$DC1_URL" "$USER" "$PASS" --no-color
$MC alias set minio-dc2 "$DC2_URL" "$USER" "$PASS" --no-color

echo "==> Checking existing replication status..."
if $MC admin replicate info minio-dc1 --no-color 2>/dev/null | grep -q "Site Name"; then
  echo "    Site replication already configured."
  $MC admin replicate info minio-dc1 --no-color
  exit 0
fi

echo "==> Enabling site replication DC1 <-> DC2..."
$MC admin replicate add \
  "http://${USER}:${PASS}@localhost:9000" \
  "http://${USER}:${PASS}@localhost:9002" \
  --no-color

echo "==> Verifying replication status..."
$MC admin replicate info minio-dc1 --no-color

echo ""
echo "Done. MinIO site replication is active."
