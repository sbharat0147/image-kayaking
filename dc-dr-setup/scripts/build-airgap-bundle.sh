#!/usr/bin/env bash
# =============================================================================
# build-airgap-bundle.sh
# Build a self-contained airgap bundle for the DC/DR stack.
#
# Run this on an internet-connected machine (or your local-test VM that already
# has all images built/pulled).
#
# Output: airgap-bundle/
#   images/dc-dr-images.tar.gz    — all Docker images (~2-3 GB)
#   config/dc-dr-config.tar.gz    — all compose files, configs, docs, scripts
#   setup/setup-airgap.sh         — run this on the airgap VM to deploy
#   BUNDLE-MANIFEST.txt           — image list + checksums for verification
#
# Usage:
#   cd /path/to/image-kayaking
#   bash dc-dr-setup/scripts/build-airgap-bundle.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
DC_DR_DIR="${REPO_ROOT}/dc-dr-setup"
BUNDLE_DIR="${REPO_ROOT}/airgap-bundle"
IMAGES_DIR="${BUNDLE_DIR}/images"
CONFIG_DIR="${BUNDLE_DIR}/config"
SETUP_DIR="${BUNDLE_DIR}/setup"

# ── Image list ────────────────────────────────────────────────────────────────
# These must all exist locally (docker images) before running this script.
IMAGES=(
  "local/patroni:3.3.0"
  "postgres:16-bookworm"
  "minio/minio:RELEASE.2025-05-24T17-08-30Z"
  "minio/mc:RELEASE.2024-11-17T19-35-25Z"
  "prom/prometheus:v2.52.0"
  "prom/alertmanager:v0.27.0"
  "grafana/grafana-oss:11.0.0"
  "prometheuscommunity/postgres-exporter:v0.15.0"
)

# ── Colors ────────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# =============================================================================
echo ""
echo "══════════════════════════════════════════════════════"
echo "  DC/DR Airgap Bundle Builder"
echo "══════════════════════════════════════════════════════"
echo ""

# ── Step 1: Verify all images exist locally ───────────────────────────────────
info "Step 1/5 — Verifying all required images are present locally..."
MISSING=()
for img in "${IMAGES[@]}"; do
  if docker image inspect "$img" &>/dev/null; then
    echo "  ✓ $img"
  else
    echo "  ✗ $img  ← MISSING"
    MISSING+=("$img")
  fi
done

if [ ${#MISSING[@]} -gt 0 ]; then
  echo ""
  warn "The following images are missing. Pull or build them first:"
  for img in "${MISSING[@]}"; do
    echo "  docker pull $img"
  done
  echo ""
  echo "  For local/patroni:3.3.0 (must be built locally):"
  echo "  docker build -t local/patroni:3.3.0 -f ${DC_DR_DIR}/patroni/Dockerfile ${DC_DR_DIR}/patroni/"
  echo ""
  error "Aborting — missing images. Fix above then re-run."
fi

echo ""
info "All images present."

# ── Step 2: Create bundle directories ────────────────────────────────────────
info "Step 2/5 — Creating bundle directory structure..."
rm -rf "${BUNDLE_DIR}"
mkdir -p "${IMAGES_DIR}" "${CONFIG_DIR}" "${SETUP_DIR}"
echo "  Bundle dir: ${BUNDLE_DIR}"

# ── Step 3: Save all Docker images ───────────────────────────────────────────
info "Step 3/5 — Saving Docker images (this will take a few minutes)..."
echo "  Images: ${IMAGES[*]}"
echo ""

docker save "${IMAGES[@]}" | gzip > "${IMAGES_DIR}/dc-dr-images.tar.gz"

IMAGE_SIZE=$(du -sh "${IMAGES_DIR}/dc-dr-images.tar.gz" | cut -f1)
info "Images saved: ${IMAGES_DIR}/dc-dr-images.tar.gz  (${IMAGE_SIZE})"

# ── Step 4: Bundle config files ───────────────────────────────────────────────
info "Step 4/5 — Bundling config files..."

tar -czf "${CONFIG_DIR}/dc-dr-config.tar.gz" \
  -C "${REPO_ROOT}" \
  dc-dr-setup/docker-compose.dc1.yml \
  dc-dr-setup/docker-compose.dc2-local.yml \
  dc-dr-setup/docker-compose.dc2.yml \
  dc-dr-setup/.env.example \
  dc-dr-setup/patroni/Dockerfile \
  dc-dr-setup/patroni/entrypoint.sh \
  dc-dr-setup/patroni/patroni.dc1.yml \
  dc-dr-setup/patroni/patroni.dc2-local.yml \
  dc-dr-setup/patroni/patroni.dc2.yml \
  dc-dr-setup/patroni/patroni.witness-local.yml \
  dc-dr-setup/postgres/postgresql.conf \
  dc-dr-setup/postgres/pg_hba.conf \
  dc-dr-setup/postgres/pgbackrest.conf \
  dc-dr-setup/minio/mc-site-replication.sh \
  dc-dr-setup/monitoring/prometheus.yml \
  dc-dr-setup/monitoring/alerting-rules.yml \
  dc-dr-setup/scripts/ \
  dc-dr-setup/docs/

CONFIG_SIZE=$(du -sh "${CONFIG_DIR}/dc-dr-config.tar.gz" | cut -f1)
info "Config bundled: ${CONFIG_DIR}/dc-dr-config.tar.gz  (${CONFIG_SIZE})"

# ── Step 5: Generate manifest (checksums) ─────────────────────────────────────
info "Step 5/5 — Generating bundle manifest..."

MANIFEST="${BUNDLE_DIR}/BUNDLE-MANIFEST.txt"
cat > "${MANIFEST}" << EOF
DC/DR Airgap Bundle Manifest
Generated: $(date -u '+%Y-%m-%d %H:%M:%S UTC')
Builder:   $(hostname)

═══════════════════════════════════════
Docker Images included
═══════════════════════════════════════
EOF

for img in "${IMAGES[@]}"; do
  DIGEST=$(docker image inspect "$img" --format '{{index .RepoDigests 0}}' 2>/dev/null || echo "local-build")
  SIZE=$(docker image inspect "$img" --format '{{.Size}}' | awk '{printf "%.0f MB", $1/1024/1024}')
  echo "  ${img}" >> "${MANIFEST}"
  echo "    Size:   ${SIZE}" >> "${MANIFEST}"
  echo "    Digest: ${DIGEST}" >> "${MANIFEST}"
  echo "" >> "${MANIFEST}"
done

cat >> "${MANIFEST}" << EOF
═══════════════════════════════════════
Bundle File Checksums (SHA256)
═══════════════════════════════════════
EOF

sha256sum "${IMAGES_DIR}/dc-dr-images.tar.gz" >> "${MANIFEST}"
sha256sum "${CONFIG_DIR}/dc-dr-config.tar.gz" >> "${MANIFEST}"

cat >> "${MANIFEST}" << EOF

═══════════════════════════════════════
Stack Versions
═══════════════════════════════════════
PostgreSQL:          16 (Bookworm)
Patroni:             3.3.0
Raft DCS:            pysyncobj (built into Patroni)
MinIO:               RELEASE.2025-05-24T17-08-30Z
MinIO Client (mc):   RELEASE.2024-11-17T19-35-25Z
Prometheus:          v2.52.0
Alertmanager:        v0.27.0
Grafana:             11.0.0
postgres_exporter:   v0.15.0

═══════════════════════════════════════
Deployment Notes
═══════════════════════════════════════
- Load images BEFORE starting any containers
- Start DC1 first, wait 30s, then start DC2+witness
- MinIO site replication must be wired after both MinIO instances are healthy
- See setup/setup-airgap.sh for the automated setup script
- See dc-dr-setup/docs/ for full documentation
EOF

info "Manifest written: ${MANIFEST}"

# ── Copy setup script into bundle ─────────────────────────────────────────────
cp "${DC_DR_DIR}/scripts/setup-airgap.sh" "${SETUP_DIR}/setup-airgap.sh" 2>/dev/null || true

# ── Final summary ────────────────────────────────────────────────────────────
echo ""
echo "══════════════════════════════════════════════════════"
echo "  Bundle ready!"
echo "══════════════════════════════════════════════════════"
echo ""
echo "  Location : ${BUNDLE_DIR}/"
echo ""
echo "  Contents :"
find "${BUNDLE_DIR}" -type f | sort | while read -r f; do
  SIZE=$(du -sh "$f" | cut -f1)
  echo "    ${SIZE}  ${f#${REPO_ROOT}/}"
done
echo ""
echo "  Next steps:"
echo "  1. Copy the entire airgap-bundle/ directory to USB or internal transfer"
echo "  2. On the airgap VM: run  bash setup/setup-airgap.sh"
echo "  3. Follow dc-dr-setup/docs/03-deployment-runbook.md for full deployment"
echo ""
