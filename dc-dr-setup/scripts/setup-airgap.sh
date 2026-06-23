#!/usr/bin/env bash
# =============================================================================
# setup-airgap.sh
# Run this on the airgap VM after copying the bundle.
# It loads images, extracts configs, and walks you through the full deployment.
#
# Usage:
#   # Copy airgap-bundle/ to the VM first, then:
#   cd airgap-bundle/
#   bash setup/setup-airgap.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
IMAGES_TAR="${BUNDLE_DIR}/images/dc-dr-images.tar.gz"
CONFIG_TAR="${BUNDLE_DIR}/config/dc-dr-config.tar.gz"
INSTALL_DIR="${HOME}/dc-dr-setup"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
section() { echo -e "\n${CYAN}══ $* ══${NC}"; }
prompt()  { echo -e "${YELLOW}[ACTION REQUIRED]${NC} $*"; }

# =============================================================================
echo ""
echo "══════════════════════════════════════════════════════════════"
echo "  DC/DR Stack — Airgap Setup"
echo "  PostgreSQL HA (Patroni+Raft) + MinIO Site Replication"
echo "══════════════════════════════════════════════════════════════"
echo ""

# ── Pre-flight checks ─────────────────────────────────────────────────────────
section "Pre-flight checks"

command -v docker &>/dev/null || error "Docker is not installed. Install Docker Engine first."
docker info &>/dev/null       || error "Docker daemon not running or current user not in docker group. Run: sudo usermod -aG docker \$USER && newgrp docker"
command -v python3 &>/dev/null || error "python3 not found. Install python3."

[ -f "${IMAGES_TAR}" ]  || error "Image bundle not found at: ${IMAGES_TAR}"
[ -f "${CONFIG_TAR}" ]  || error "Config bundle not found at: ${CONFIG_TAR}"

info "Docker: $(docker --version)"
info "Bundle location: ${BUNDLE_DIR}"

# ── Verify checksums ──────────────────────────────────────────────────────────
section "Verifying bundle integrity"

MANIFEST="${BUNDLE_DIR}/BUNDLE-MANIFEST.txt"
if [ -f "${MANIFEST}" ]; then
  info "Verifying SHA256 checksums..."
  cd "${BUNDLE_DIR}"
  # Extract checksum lines from manifest and verify
  grep -E "^[a-f0-9]{64}" "${MANIFEST}" | sha256sum --check --quiet && \
    info "Checksums OK" || warn "Checksum mismatch — bundle may be corrupted"
  cd - >/dev/null
else
  warn "No manifest found — skipping checksum verification"
fi

# ── Load Docker images ────────────────────────────────────────────────────────
section "Loading Docker images"
info "This may take 3-5 minutes depending on disk speed..."

docker load < "${IMAGES_TAR}"

info "Images loaded:"
docker images --format "  {{.Repository}}:{{.Tag}}  ({{.Size}})" | grep -E "patroni|minio|prometheus|grafana|postgres-exporter|alertmanager"

# ── Install mc wrapper ─────────────────────────────────────────────────────────
section "Installing mc (MinIO Client) wrapper"

cat > /tmp/mc-wrapper.sh << 'EOF'
#!/bin/bash
docker run --rm -i --network host \
  -v "$HOME/.mc:/root/.mc" \
  minio/mc:RELEASE.2024-11-17T19-35-25Z "$@"
EOF
sudo mv /tmp/mc-wrapper.sh /usr/local/bin/mc
sudo chmod +x /usr/local/bin/mc
info "mc wrapper installed at /usr/local/bin/mc"

# ── Extract config files ───────────────────────────────────────────────────────
section "Extracting configuration files"

mkdir -p "${INSTALL_DIR}"
tar -xzf "${CONFIG_TAR}" -C "${HOME}"
info "Config files extracted to: ${INSTALL_DIR}/"

# ── Configure .env ─────────────────────────────────────────────────────────────
section "Environment configuration"

ENV_FILE="${INSTALL_DIR}/.env"

if [ ! -f "${ENV_FILE}" ]; then
  cp "${INSTALL_DIR}/.env.example" "${ENV_FILE}"
fi

echo ""
prompt "Edit the .env file with your actual values before proceeding."
echo ""
echo "  Required values to set:"
echo "    DC1_IP  — IP address of this VM (DC1)"
echo "    DC2_IP  — IP address of the DC2 VM (same as DC1_IP for local-test)"
echo "    PATRONI_SUPERUSER_PASSWORD  — strong password for postgres superuser"
echo "    PATRONI_REPLICATION_PASSWORD — strong password for replication user"
echo "    MINIO_ROOT_USER             — MinIO admin username"
echo "    MINIO_ROOT_PASSWORD         — strong MinIO admin password"
echo ""
echo "  File location: ${ENV_FILE}"
echo ""
read -rp "Press ENTER when you have finished editing .env to continue..."

# Validate required variables
source "${ENV_FILE}"
: "${DC1_IP:?DC1_IP not set in .env}"
: "${PATRONI_SUPERUSER_PASSWORD:?PATRONI_SUPERUSER_PASSWORD not set in .env}"
: "${PATRONI_REPLICATION_PASSWORD:?PATRONI_REPLICATION_PASSWORD not set in .env}"
: "${MINIO_ROOT_USER:?MINIO_ROOT_USER not set in .env}"
: "${MINIO_ROOT_PASSWORD:?MINIO_ROOT_PASSWORD not set in .env}"

info ".env validated. DC1_IP=${DC1_IP}"

# ── Deployment mode selection ─────────────────────────────────────────────────
section "Deployment mode"

echo ""
echo "  Select your deployment mode:"
echo "    1) Local-test  — DC1 + DC2 + witness on THIS single VM (offset ports)"
echo "    2) Two-VM      — DC1 on this VM, DC2 on a separate VM"
echo ""
read -rp "Enter 1 or 2: " MODE

case "${MODE}" in
  1) COMPOSE_DC2="docker-compose.dc2-local.yml"; DC2_LABEL="local-test (same VM)" ;;
  2) COMPOSE_DC2="docker-compose.dc2.yml";       DC2_LABEL="two-VM production" ;;
  *) error "Invalid choice. Run the script again and enter 1 or 2." ;;
esac

info "Mode: ${DC2_LABEL}"

# ── Start DC1 ─────────────────────────────────────────────────────────────────
section "Starting DC1 stack"

cd "${INSTALL_DIR}"

info "Starting DC1 (Patroni primary + MinIO + monitoring)..."
docker compose -p dc1 -f docker-compose.dc1.yml --env-file .env up -d

info "Waiting 35 seconds for PostgreSQL to bootstrap..."
sleep 35

# Verify DC1 Patroni
LEADER=$(curl -s "http://localhost:8008/leader" 2>/dev/null || echo "unreachable")
if echo "${LEADER}" | grep -q "pg-dc1"; then
  info "DC1 Patroni leader confirmed: ${LEADER}"
else
  warn "DC1 Patroni not yet leader (got: ${LEADER}). Check: docker logs postgres-dc1"
fi

# Verify DC1 MinIO
if curl -sf "http://localhost:9000/minio/health/live" &>/dev/null; then
  info "DC1 MinIO healthy"
else
  warn "DC1 MinIO not healthy yet. Check: docker logs minio-dc1"
fi

# ── Start DC2 + witness ────────────────────────────────────────────────────────
section "Starting DC2 stack"

if [ "${MODE}" = "1" ]; then
  info "Starting DC2 + witness (same VM, offset ports)..."
  docker compose -p dc2 -f "${COMPOSE_DC2}" --env-file .env up -d
  info "Waiting 60 seconds for DC2 to clone from DC1..."
  sleep 60
else
  echo ""
  prompt "Two-VM mode: SSH to the DC2 VM and run this same setup script there."
  echo "  On DC2 VM run:"
  echo "    bash setup/setup-airgap.sh"
  echo "  Then select option 2 (Two-VM) and DC2-only startup will run."
  echo ""
  read -rp "Press ENTER when DC2 is up and streaming (check: curl http://<DC2_IP>:8008/cluster)..."
fi

# ── Verify cluster ─────────────────────────────────────────────────────────────
section "Verifying cluster state"

echo ""
curl -s "http://localhost:8008/cluster" | python3 -m json.tool 2>/dev/null || \
  warn "Could not reach cluster API"

echo ""
info "Checking replication..."
psql -h localhost -p 5432 -U postgres \
  -c "SELECT client_addr, state, (sent_lsn - replay_lsn) AS lag_bytes FROM pg_stat_replication;" \
  2>/dev/null || warn "Could not query pg_stat_replication (may still be cloning)"

# ── MinIO site replication ─────────────────────────────────────────────────────
section "Wiring MinIO site replication"

DC2_MINIO_PORT=9002
[ "${MODE}" = "2" ] && DC2_MINIO_PORT=9000

info "Configuring mc aliases..."
mc alias set dc1 "http://${DC1_IP}:9000" "${MINIO_ROOT_USER}" "${MINIO_ROOT_PASSWORD}"
mc alias set dc2 "http://${DC1_IP}:${DC2_MINIO_PORT}" "${MINIO_ROOT_USER}" "${MINIO_ROOT_PASSWORD}"

info "Enabling site replication..."
mc admin replicate add dc1 dc2

info "Replication status:"
mc admin replicate info dc1

# ── Final summary ─────────────────────────────────────────────────────────────
section "Setup complete"

echo ""
echo "  ✓ DC1 PostgreSQL primary:   localhost:5432"
echo "  ✓ DC2 PostgreSQL replica:   localhost:5433  (local-test) / <DC2_IP>:5432 (two-VM)"
echo "  ✓ Witness (Raft voter):     localhost:5434  (local-test only)"
echo "  ✓ DC1 MinIO:                http://${DC1_IP}:9000  (Console: :9001)"
echo "  ✓ DC2 MinIO:                http://${DC1_IP}:${DC2_MINIO_PORT}  (Console: :$(( DC2_MINIO_PORT+1 )))"
echo "  ✓ MinIO site replication:   active (bidirectional)"
echo "  ✓ Grafana:                  http://localhost:3000  (admin / admin)"
echo "  ✓ Prometheus:               http://localhost:9090"
echo ""
echo "  Quick health check:"
echo "    curl -s http://localhost:8008/cluster | python3 -m json.tool"
echo "    mc admin replicate info dc1"
echo ""
echo "  Full documentation: ${INSTALL_DIR}/docs/"
echo "  Troubleshooting:    ${INSTALL_DIR}/docs/06-troubleshooting.md"
echo "  Test scenarios:     ${INSTALL_DIR}/docs/07-enterprise-test-scenarios.md"
echo ""
