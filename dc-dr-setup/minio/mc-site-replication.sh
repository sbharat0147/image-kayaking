#!/usr/bin/env bash
# Wire up MinIO Site Replication between DC1 and DC2.
# Run this ONCE after both MinIO instances are up and healthy.
# Requires: mc (MinIO Client) installed locally or in PATH.

set -euo pipefail

: "${DC1_IP:?DC1_IP not set}"
: "${DC2_IP:?DC2_IP not set}"
: "${MINIO_ROOT_USER:?MINIO_ROOT_USER not set}"
: "${MINIO_ROOT_PASSWORD:?MINIO_ROOT_PASSWORD not set}"

MC=mc

echo "==> Configuring mc aliases..."
$MC alias set dc1 "http://${DC1_IP}:9000" "${MINIO_ROOT_USER}" "${MINIO_ROOT_PASSWORD}"
$MC alias set dc2 "http://${DC2_IP}:9000" "${MINIO_ROOT_USER}" "${MINIO_ROOT_PASSWORD}"

echo "==> Enabling Site Replication between dc1 and dc2..."
$MC admin replicate add dc1 dc2

echo "==> Verifying replication status..."
$MC admin replicate info dc1

echo ""
echo "Site replication is active. All existing and future buckets will sync."
echo "Note: Both sites must use the same root credentials (already set above)."
