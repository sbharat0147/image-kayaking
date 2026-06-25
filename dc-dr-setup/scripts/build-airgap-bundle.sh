#!/usr/bin/env bash
# =============================================================================
# build-airgap-bundle.sh
# Build a fully self-contained airgap bundle for the DC/DR stack on RHEL 9.
#
# Run this on an INTERNET-CONNECTED machine (any OS with Docker installed).
# The output bundle is completely self-contained — no internet access needed
# on the target RHEL 9 VMs.
#
# What is bundled:
#   images/dc-dr-images.tar.gz        — all Docker images (~3-5 GB)
#   config/dc-dr-config.tar.gz        — all compose files, configs, scripts, docs
#   rpms/docker/                      — Docker CE + Compose RPMs for RHEL 9 x86_64
#   rpms/deps/                        — System dep RPMs (container-selinux, etc.)
#   pip-wheels/podman-compose/        — podman-compose + all pip deps
#   tools/jq                          — jq static binary (json processor)
#   install-scripts/                  — Step-by-step install scripts for RHEL 9
#   README-FIRST.txt                  — Start-here instructions
#   BUNDLE-MANIFEST.txt               — Contents + checksums
#
# Usage:
#   cd /path/to/image-kayaking
#   bash dc-dr-setup/scripts/build-airgap-bundle.sh
#
# Prerequisites on BUILD machine:
#   - Docker Engine 24+ running
#   - Internet access
#   - Python 3 (for pip wheels download)
#   - ~15 GB free disk space
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
DC_DR_DIR="${REPO_ROOT}/dc-dr-setup"
DATE_TAG=$(date +%Y-%m-%d)
BUNDLE_DIR="${REPO_ROOT}/airgap-bundle-${DATE_TAG}"

IMAGES_DIR="${BUNDLE_DIR}/images"
CONFIG_DIR="${BUNDLE_DIR}/config"
RPMS_DOCKER="${BUNDLE_DIR}/rpms/docker"
RPMS_DEPS="${BUNDLE_DIR}/rpms/deps"
WHEELS_DIR="${BUNDLE_DIR}/pip-wheels/podman-compose"
TOOLS_DIR="${BUNDLE_DIR}/tools"
INSTALL_SCRIPTS_DIR="${BUNDLE_DIR}/install-scripts"

# ── Docker images to bundle ───────────────────────────────────────────────────
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

# ── Colours ───────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
section() { echo -e "\n${CYAN}════════════════════════════════════════${NC}"; echo -e "${CYAN}  $*${NC}"; echo -e "${CYAN}════════════════════════════════════════${NC}"; }
step()    { echo -e "\n  ${GREEN}▶${NC} $*"; }

# =============================================================================
echo ""
echo -e "${CYAN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║   DC/DR Airgap Bundle Builder — RHEL 9 Edition           ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo "  Bundle output : ${BUNDLE_DIR}"
echo "  Build date    : ${DATE_TAG}"
echo ""

# =============================================================================
section "Step 1/8 — Verify Docker images are present locally"
# =============================================================================

MISSING=()
for img in "${IMAGES[@]}"; do
  if docker image inspect "$img" &>/dev/null; then
    printf "  ✓  %-60s\n" "$img"
  else
    printf "  ✗  %-60s  ← MISSING\n" "$img"
    MISSING+=("$img")
  fi
done

if [ ${#MISSING[@]} -gt 0 ]; then
  echo ""
  warn "Missing images. Build or pull them first:"
  echo ""
  echo "  # Build Patroni (must be built locally):"
  echo "  docker build -t local/patroni:3.3.0 \\"
  echo "    -f ${DC_DR_DIR}/patroni/Dockerfile ${DC_DR_DIR}/patroni/"
  echo ""
  echo "  # Pull all upstream images:"
  for img in "${MISSING[@]}"; do
    [[ "$img" == local/* ]] && continue
    echo "  docker pull $img"
  done
  echo ""
  error "Aborting — fix missing images then re-run."
fi

info "All ${#IMAGES[@]} images verified."

# =============================================================================
section "Step 2/8 — Create bundle directory structure"
# =============================================================================

rm -rf "${BUNDLE_DIR}"
mkdir -p \
  "${IMAGES_DIR}" \
  "${CONFIG_DIR}" \
  "${RPMS_DOCKER}" \
  "${RPMS_DEPS}" \
  "${WHEELS_DIR}" \
  "${TOOLS_DIR}" \
  "${INSTALL_SCRIPTS_DIR}"

info "Bundle directory created: ${BUNDLE_DIR}"

# =============================================================================
section "Step 3/8 — Save Docker images to tarball"
# =============================================================================

info "Saving ${#IMAGES[@]} images — this takes 5–15 minutes..."
echo "  Images: "
for img in "${IMAGES[@]}"; do echo "    - $img"; done
echo ""

docker save "${IMAGES[@]}" | gzip > "${IMAGES_DIR}/dc-dr-images.tar.gz"

IMAGE_SIZE=$(du -sh "${IMAGES_DIR}/dc-dr-images.tar.gz" | cut -f1)
info "Saved: ${IMAGES_DIR}/dc-dr-images.tar.gz  (${IMAGE_SIZE})"

# =============================================================================
section "Step 4/8 — Download Docker CE RPMs for RHEL 9 x86_64"
# =============================================================================
# Uses a CentOS Stream 9 container (free, Docker-capable, RHEL-compatible)
# to run dnf download --resolve, capturing all transitive RPM dependencies.

info "Pulling CentOS Stream 9 builder container..."
docker pull --platform linux/amd64 quay.io/centos/centos:stream9 2>/dev/null || \
  docker pull --platform linux/amd64 quay.io/centos/centos:stream9

info "Downloading Docker CE RPMs inside centos:stream9 container..."
info "(This resolves all RPM dependencies — takes 2-3 minutes)"

docker run --rm \
  --platform linux/amd64 \
  -v "${RPMS_DOCKER}:/rpms-docker" \
  -v "${RPMS_DEPS}:/rpms-deps" \
  quay.io/centos/centos:stream9 \
  bash -c "
    set -euo pipefail
    echo '--- Updating dnf cache ---'
    dnf -y -q install 'dnf-command(config-manager)' yum-utils 2>/dev/null || true

    echo '--- Adding Docker CE repo ---'
    dnf config-manager --add-repo \
      https://download.docker.com/linux/centos/docker-ce.repo

    echo '--- Downloading Docker CE + Compose plugin RPMs ---'
    dnf download \
      --resolve \
      --alldeps \
      --arch=x86_64 \
      --destdir=/rpms-docker \
      docker-ce \
      docker-ce-cli \
      containerd.io \
      docker-compose-plugin \
      docker-buildx-plugin \
      2>&1 | grep -v '^$'

    echo '--- Downloading system dependency RPMs ---'
    dnf download \
      --resolve \
      --arch=x86_64 \
      --destdir=/rpms-deps \
      container-selinux \
      libcgroup \
      fuse-overlayfs \
      slirp4netns \
      2>&1 | grep -v '^$' || true

    echo '--- Done ---'
    echo 'Docker RPMs downloaded:'
    ls -1 /rpms-docker/*.rpm 2>/dev/null | wc -l
    echo 'Dep RPMs downloaded:'
    ls -1 /rpms-deps/*.rpm 2>/dev/null | wc -l
  " || {
    warn "RPM download via container failed (proxy/network issue)."
    warn "The bundle will still work — see install-scripts/01-install-docker-rhel9.sh"
    warn "for the manual RPM download procedure on a RHEL 9 machine with internet."
    warn "Or use Podman (pre-installed on RHEL 9) with install-scripts/02-install-podman-compose.sh"
    echo "" > "${RPMS_DOCKER}/.download-failed"
  }

DOCKER_RPM_COUNT=$(ls "${RPMS_DOCKER}"/*.rpm 2>/dev/null | wc -l)
DEPS_RPM_COUNT=$(ls "${RPMS_DEPS}"/*.rpm 2>/dev/null | wc -l)
info "Docker RPMs downloaded : ${DOCKER_RPM_COUNT} packages"
info "Dependency RPMs        : ${DEPS_RPM_COUNT} packages"

# =============================================================================
section "Step 5/8 — Download podman-compose pip wheels"
# =============================================================================
# podman is pre-installed on RHEL 9. podman-compose is installed via pip.
# We download all wheels so pip install --no-index works offline.

info "Downloading podman-compose wheels (Python 3.11 / manylinux)..."

docker run --rm \
  --platform linux/amd64 \
  -v "${WHEELS_DIR}:/wheels" \
  python:3.11-slim \
  pip download \
    --no-cache-dir \
    --platform manylinux_2_28_x86_64 \
    --python-version 3.11 \
    --only-binary=:all: \
    --trusted-host pypi.org \
    --trusted-host files.pythonhosted.org \
    --trusted-host pypi.python.org \
    podman-compose \
    pyyaml \
    -d /wheels \
    2>&1 | grep -E "^(Collecting|  Downloading|Successfully)" || true

# Also grab pure-python wheels (some packages are py3-any)
docker run --rm \
  --platform linux/amd64 \
  -v "${WHEELS_DIR}:/wheels" \
  python:3.11-slim \
  pip download \
    --no-cache-dir \
    --no-binary=:all: \
    --trusted-host pypi.org \
    --trusted-host files.pythonhosted.org \
    podman-compose \
    pyyaml \
    -d /wheels \
    2>&1 | grep -E "^(Collecting|  Downloading|Successfully)" || true

WHEEL_COUNT=$(ls "${WHEELS_DIR}"/*.whl "${WHEELS_DIR}"/*.tar.gz 2>/dev/null | wc -l)
info "pip wheels downloaded: ${WHEEL_COUNT} packages"

# =============================================================================
section "Step 6/8 — Download static tools"
# =============================================================================

# jq — static binary, no install needed
JQ_VERSION="1.7.1"
info "Downloading jq ${JQ_VERSION} (static binary)..."
curl -fsSL --retry 3 \
  "https://github.com/jqlang/jq/releases/download/jq-${JQ_VERSION}/jq-linux-amd64" \
  -o "${TOOLS_DIR}/jq" && \
  chmod +x "${TOOLS_DIR}/jq" && \
  info "jq downloaded: $(${TOOLS_DIR}/jq --version 2>/dev/null)" || \
  warn "jq download failed — install from EPEL on the target VM"

# =============================================================================
section "Step 7/8 — Bundle config files and install scripts"
# =============================================================================

step "Packaging DC/DR config files..."

# Gather all config files — exclude local .env files (contain secrets)
tar -czf "${CONFIG_DIR}/dc-dr-config.tar.gz" \
  -C "${REPO_ROOT}" \
  --exclude='dc-dr-setup/.env' \
  --exclude='dc-dr-setup/.env.local' \
  --exclude='dc-dr-setup/.env.production' \
  --exclude='dc-dr-setup/PLAN.md' \
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

CONFIG_SIZE=$(du -sh "${CONFIG_DIR}/dc-dr-config.tar.gz" | cut -f1)
info "Config tarball: ${CONFIG_SIZE}"

step "Writing install scripts for RHEL 9..."

# ── Install script 01: Install Docker CE ─────────────────────────────────────
cat > "${INSTALL_SCRIPTS_DIR}/01-install-docker-rhel9.sh" << 'SCRIPT'
#!/usr/bin/env bash
# =============================================================================
# 01-install-docker-rhel9.sh
# Install Docker CE on RHEL 9 from bundled RPMs.
# Run as root or with sudo on the airgap RHEL 9 VM.
#
# Usage: sudo bash 01-install-docker-rhel9.sh
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
RPMS_DOCKER="${BUNDLE_DIR}/rpms/docker"
RPMS_DEPS="${BUNDLE_DIR}/rpms/deps"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

echo ""
echo "╔══════════════════════════════════════════╗"
echo "║  Docker CE Install — RHEL 9 (Offline)    ║"
echo "╚══════════════════════════════════════════╝"
echo ""

# Confirm running as root
[ "$(id -u)" -eq 0 ] || error "This script must be run as root: sudo bash $0"

# Check RHEL 9
if [ -f /etc/os-release ]; then
  . /etc/os-release
  [[ "${ID}" =~ ^(rhel|centos|rocky|almalinux)$ ]] || \
    warn "OS is '${ID}' — these RPMs are packaged for RHEL 9 / CentOS Stream 9"
  [[ "${VERSION_ID}" =~ ^9 ]] || \
    warn "OS version is ${VERSION_ID} — RPMs were built for version 9"
fi

# Check if Docker already installed
if command -v docker &>/dev/null; then
  info "Docker is already installed: $(docker --version)"
  read -rp "Reinstall/upgrade? [y/N]: " REPLY
  [[ "${REPLY,,}" == "y" ]] || { info "Skipping Docker install."; exit 0; }
fi

# Verify RPMs exist
RPM_COUNT=$(ls "${RPMS_DOCKER}"/*.rpm 2>/dev/null | wc -l)
if [ "${RPM_COUNT}" -eq 0 ]; then
  error "No RPMs found in ${RPMS_DOCKER}/
If the bundle was built without RPMs (download failed), fetch them manually:
  On a RHEL 9 / CentOS Stream 9 machine with internet:
    sudo dnf config-manager --add-repo \\
      https://download.docker.com/linux/centos/docker-ce.repo
    dnf download --resolve --alldeps --destdir=./docker-rpms \\
      docker-ce docker-ce-cli containerd.io \\
      docker-compose-plugin docker-buildx-plugin
  Copy the ./docker-rpms/ directory to this VM and re-run."
fi

info "Found ${RPM_COUNT} Docker CE RPMs"

# Remove any old Docker versions (if present)
info "Removing old Docker versions (if any)..."
dnf -y remove \
  docker docker-client docker-client-latest docker-common \
  docker-latest docker-latest-logrotate docker-logrotate \
  docker-engine podman runc \
  2>/dev/null || true

# Install dependency RPMs first (container-selinux etc.)
DEP_COUNT=$(ls "${RPMS_DEPS}"/*.rpm 2>/dev/null | wc -l)
if [ "${DEP_COUNT}" -gt 0 ]; then
  info "Installing ${DEP_COUNT} dependency RPMs..."
  dnf localinstall -y --disablerepo='*' "${RPMS_DEPS}"/*.rpm || {
    warn "Some dep RPMs failed — they may already be installed. Continuing..."
  }
fi

# Install Docker CE RPMs
info "Installing Docker CE from local RPMs..."
dnf localinstall -y --disablerepo='*' "${RPMS_DOCKER}"/*.rpm

# Enable and start Docker
info "Enabling and starting Docker service..."
systemctl enable --now docker

# Add current user to docker group
SUDO_USER="${SUDO_USER:-$(logname 2>/dev/null || echo '')}"
if [ -n "${SUDO_USER}" ] && [ "${SUDO_USER}" != "root" ]; then
  usermod -aG docker "${SUDO_USER}"
  info "Added ${SUDO_USER} to docker group."
  info "Run 'newgrp docker' or log out and back in to use docker without sudo."
fi

# Verify
docker --version
docker compose version

info ""
info "Docker CE installed successfully."
info ""
info "Test: docker run --rm hello-world   (uses bundled images — no internet)"
SCRIPT
chmod +x "${INSTALL_SCRIPTS_DIR}/01-install-docker-rhel9.sh"

# ── Install script 02: Podman + podman-compose (alternative) ─────────────────
cat > "${INSTALL_SCRIPTS_DIR}/02-install-podman-compose.sh" << 'SCRIPT'
#!/usr/bin/env bash
# =============================================================================
# 02-install-podman-compose.sh
# Install podman-compose on RHEL 9 using bundled pip wheels.
#
# Podman is pre-installed on RHEL 9 (or available from local ISO/Satellite).
# This script only adds podman-compose (Docker Compose compatibility layer).
#
# Usage: sudo bash 02-install-podman-compose.sh
# Note: After install, use 'podman-compose' instead of 'docker compose'
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
WHEELS_DIR="${BUNDLE_DIR}/pip-wheels/podman-compose"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

echo ""
echo "╔═══════════════════════════════════════════════╗"
echo "║  podman-compose Install — RHEL 9 (Offline)    ║"
echo "╚═══════════════════════════════════════════════╝"
echo ""

# Check podman
if ! command -v podman &>/dev/null; then
  error "podman not found. Install it first:
  If you have a RHEL subscription or local Satellite:
    sudo dnf install -y podman

  If running from RHEL 9 ISO (no subscription):
    sudo dnf install -y --disablerepo='*' \\
      --enablerepo='BaseOS,AppStream' podman

  Podman is included in RHEL 9 BaseOS — it should be available from
  the installation media without any internet access."
fi

info "Podman version: $(podman --version)"

# Check python3 + pip
if ! command -v python3 &>/dev/null; then
  error "python3 not found. Install it: sudo dnf install -y python3"
fi

if ! python3 -m pip --version &>/dev/null 2>&1; then
  error "pip not found. Install it: sudo dnf install -y python3-pip"
fi

# Check wheels
WHEEL_COUNT=$(ls "${WHEELS_DIR}"/*.whl "${WHEELS_DIR}"/*.tar.gz 2>/dev/null | wc -l)
if [ "${WHEEL_COUNT}" -eq 0 ]; then
  error "No pip wheels found in ${WHEELS_DIR}/"
fi

info "Installing podman-compose from ${WHEEL_COUNT} bundled wheels..."

pip3 install \
  --no-index \
  --find-links "${WHEELS_DIR}" \
  --trusted-host "" \
  podman-compose

# Verify
podman-compose --version

info ""
info "podman-compose installed successfully."
info ""
info "Usage note: The DC/DR scripts use 'docker compose' syntax."
info "With podman-compose, replace 'docker compose' with 'podman-compose':"
info ""
info "  docker compose -p dc1 -f docker-compose.dc1.yml up -d"
info "  ↓ becomes"
info "  podman-compose --pod-args=\"\" -f docker-compose.dc1.yml up -d"
info ""
info "Or create an alias:  alias docker='podman'"
info "And:                 alias 'docker compose'='podman-compose'"
SCRIPT
chmod +x "${INSTALL_SCRIPTS_DIR}/02-install-podman-compose.sh"

# ── Install script 03: Load Docker images ─────────────────────────────────────
cat > "${INSTALL_SCRIPTS_DIR}/03-load-images.sh" << 'SCRIPT'
#!/usr/bin/env bash
# =============================================================================
# 03-load-images.sh
# Load all DC/DR Docker images from the bundle into the local Docker daemon.
# Run this after installing Docker (script 01) or with Podman (script 02).
#
# Usage: bash 03-load-images.sh
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
IMAGES_TAR="${BUNDLE_DIR}/images/dc-dr-images.tar.gz"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

echo ""
echo "╔═══════════════════════════════════════╗"
echo "║  Load DC/DR Docker Images             ║"
echo "╚═══════════════════════════════════════╝"
echo ""

[ -f "${IMAGES_TAR}" ] || error "Image tarball not found: ${IMAGES_TAR}"

RUNTIME="docker"
if ! command -v docker &>/dev/null; then
  if command -v podman &>/dev/null; then
    RUNTIME="podman"
    warn "docker not found — using podman instead"
  else
    error "Neither docker nor podman is installed. Run script 01 or 02 first."
  fi
fi

info "Runtime: ${RUNTIME} ($(${RUNTIME} --version | head -1))"
info "Image file: ${IMAGES_TAR}  ($(du -sh "${IMAGES_TAR}" | cut -f1))"
info "Loading images — this takes 3–10 minutes on first load..."
echo ""

${RUNTIME} load < "${IMAGES_TAR}"

echo ""
info "Images loaded. Verifying:"
echo ""
${RUNTIME} images --format "  {{.Repository}}:{{.Tag}}  ({{.Size}})" | \
  grep -E "patroni|minio|prometheus|grafana|postgres-exporter|alertmanager" | sort

echo ""
info "All images ready. Proceed to: 04-deploy-dc1.sh"
SCRIPT
chmod +x "${INSTALL_SCRIPTS_DIR}/03-load-images.sh"

# ── Install script 04: Deploy DC1 ─────────────────────────────────────────────
cat > "${INSTALL_SCRIPTS_DIR}/04-deploy-dc1.sh" << 'SCRIPT'
#!/usr/bin/env bash
# =============================================================================
# 04-deploy-dc1.sh
# Deploy the DC1 stack (PostgreSQL primary + MinIO DC1 + Monitoring).
# Run on the DC1 VM after loading images (script 03).
#
# Usage: bash 04-deploy-dc1.sh
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_TAR="${BUNDLE_DIR}/config/dc-dr-config.tar.gz"
INSTALL_DIR="${HOME}/dc-dr"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
prompt()  { echo -e "${YELLOW}[ACTION]${NC} $*"; }

echo ""
echo "╔═══════════════════════════════════════════╗"
echo "║  Deploy DC1 Stack                         ║"
echo "║  PostgreSQL Primary + MinIO + Monitoring  ║"
echo "╚═══════════════════════════════════════════╝"
echo ""

# Extract config if not already done
if [ ! -d "${INSTALL_DIR}/dc-dr-setup" ]; then
  info "Extracting configuration files to ${INSTALL_DIR}..."
  mkdir -p "${INSTALL_DIR}"
  tar -xzf "${CONFIG_TAR}" -C "${INSTALL_DIR}"
fi

DC_DR="${INSTALL_DIR}/dc-dr-setup"
ENV_FILE="${DC_DR}/.env"

# First-time .env setup
if [ ! -f "${ENV_FILE}" ]; then
  cp "${DC_DR}/.env.example" "${ENV_FILE}"
  echo ""
  prompt "Configure the .env file before starting:"
  echo ""
  echo "  Required settings:"
  echo "    DC1_IP   — IP of THIS VM (reachable from DC2 VM)"
  echo "    DC2_IP   — IP of the DC2 VM (same as DC1_IP for local-test)"
  echo "    PATRONI_SUPERUSER_PASSWORD   — strong password (min 20 chars)"
  echo "    PATRONI_REPLICATION_PASSWORD — strong password (min 20 chars)"
  echo "    MINIO_ROOT_USER              — MinIO admin username"
  echo "    MINIO_ROOT_PASSWORD          — strong MinIO admin password"
  echo ""
  echo "  Generate strong passwords with: openssl rand -base64 24"
  echo ""
  echo "  Edit: vi ${ENV_FILE}"
  echo ""
  read -rp "Press ENTER after saving .env to continue..."
fi

# Validate required variables
set -a; source "${ENV_FILE}"; set +a
: "${DC1_IP:?DC1_IP not set in .env}"
: "${PATRONI_SUPERUSER_PASSWORD:?PATRONI_SUPERUSER_PASSWORD not set}"
: "${PATRONI_REPLICATION_PASSWORD:?PATRONI_REPLICATION_PASSWORD not set}"
: "${MINIO_ROOT_USER:?MINIO_ROOT_USER not set}"
: "${MINIO_ROOT_PASSWORD:?MINIO_ROOT_PASSWORD not set}"

info ".env validated. DC1_IP=${DC1_IP}"

# Ask about deployment mode
echo ""
echo "  Deployment mode:"
echo "    1) Local-test — DC1 + DC2 + witness on THIS machine (offset ports)"
echo "    2) Two-VM     — DC1 on this machine, DC2 on a separate VM"
echo ""
read -rp "Enter 1 or 2: " MODE

[ "${MODE}" = "1" ] || [ "${MODE}" = "2" ] || error "Enter 1 or 2"

cd "${DC_DR}"

# Warn about volume cleanup
echo ""
warn "If restarting from scratch, clean up old volumes first:"
echo "  docker compose -p dc1 -f docker-compose.dc1.yml --env-file .env down -v"
echo "  docker compose -p dc2 -f docker-compose.dc2-local.yml --env-file .env down -v"
echo ""
read -rp "Continue with startup? [Y/n]: " REPLY
[[ "${REPLY,,}" != "n" ]] || exit 0

info "Starting DC1 stack..."
docker compose -p dc1 -f docker-compose.dc1.yml --env-file .env up -d

info "Waiting 40 seconds for PostgreSQL to bootstrap..."
sleep 40

# Health check
echo ""
info "Checking DC1 health..."
echo ""
LEADER=$(curl -s "http://localhost:8008/leader" 2>/dev/null || echo "unreachable")
if echo "${LEADER}" | grep -q "pg-dc1"; then
  echo -e "  ${GREEN}✓${NC}  Patroni leader: ${LEADER}"
else
  echo -e "  ${YELLOW}⚠${NC}  Patroni leader: ${LEADER} (may still be starting)"
  echo "     Check: docker logs postgres-dc1 | tail -20"
fi

if curl -sf "http://localhost:9000/minio/health/live" &>/dev/null; then
  echo -e "  ${GREEN}✓${NC}  MinIO DC1: healthy"
else
  echo -e "  ${YELLOW}⚠${NC}  MinIO DC1: not yet healthy"
  echo "     Check: docker logs minio-dc1 | tail -10"
fi

if curl -sf "http://localhost:9090/-/healthy" &>/dev/null; then
  echo -e "  ${GREEN}✓${NC}  Prometheus: healthy"
fi

if curl -sf "http://localhost:3001/api/health" &>/dev/null; then
  echo -e "  ${GREEN}✓${NC}  Grafana: healthy (http://localhost:3001  admin/admin)"
fi

echo ""
if [ "${MODE}" = "1" ]; then
  info "Now run: bash 05-deploy-dc2.sh  (on this same machine)"
else
  info "Transfer the bundle to the DC2 VM and run: bash 04-deploy-dc1.sh"
  info "Select mode 2 on DC2 and it will start the DC2-only stack."
fi
SCRIPT
chmod +x "${INSTALL_SCRIPTS_DIR}/04-deploy-dc1.sh"

# ── Install script 05: Deploy DC2 ─────────────────────────────────────────────
cat > "${INSTALL_SCRIPTS_DIR}/05-deploy-dc2.sh" << 'SCRIPT'
#!/usr/bin/env bash
# =============================================================================
# 05-deploy-dc2.sh
# Deploy the DC2 stack (PostgreSQL replica + MinIO DC2 [+ witness]).
#
# LOCAL-TEST MODE: Run on same machine as DC1, after 04-deploy-dc1.sh
# TWO-VM MODE:     Run on the DC2 VM after transferring the bundle.
#
# Usage: bash 05-deploy-dc2.sh
# =============================================================================
set -euo pipefail

INSTALL_DIR="${HOME}/dc-dr"
DC_DR="${INSTALL_DIR}/dc-dr-setup"
ENV_FILE="${DC_DR}/.env"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()   { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()   { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()  { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
prompt() { echo -e "${YELLOW}[ACTION]${NC} $*"; }

echo ""
echo "╔═══════════════════════════════════════════╗"
echo "║  Deploy DC2 Stack                         ║"
echo "║  PostgreSQL Replica + MinIO DC2           ║"
echo "╚═══════════════════════════════════════════╝"
echo ""

[ -f "${ENV_FILE}" ] || error ".env not found. Run 04-deploy-dc1.sh first (or extract config)."

set -a; source "${ENV_FILE}"; set +a
: "${DC1_IP:?DC1_IP not set}"
: "${DC2_IP:?DC2_IP not set}"

echo "  DC1_IP = ${DC1_IP}"
echo "  DC2_IP = ${DC2_IP}"
echo ""
echo "  Mode:"
echo "    1) Local-test — DC2 + witness on THIS machine (same machine as DC1)"
echo "    2) Two-VM     — DC2 only on this separate VM"
echo ""
read -rp "Enter 1 or 2: " MODE

cd "${DC_DR}"

case "${MODE}" in
  1)
    info "Starting DC2 + witness (local-test mode)..."
    docker compose -p dc2 -f docker-compose.dc2-local.yml --env-file .env up -d
    ;;
  2)
    info "Starting DC2 only (two-VM mode)..."
    docker compose -p dc2 -f docker-compose.dc2.yml --env-file .env up -d
    ;;
  *)
    error "Enter 1 or 2"
    ;;
esac

info "Waiting 60 seconds for DC2 to clone from DC1 (pg_basebackup)..."
sleep 60

echo ""
info "Checking DC2 cluster state..."
CLUSTER=$(curl -s "http://localhost:8008/cluster" 2>/dev/null || \
          curl -s "http://${DC1_IP}:8008/cluster" 2>/dev/null || echo "{}")

echo "${CLUSTER}" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for m in data.get('members', []):
    role  = m.get('role','?')
    state = m.get('state','?')
    lag   = m.get('lag','?')
    name  = m.get('name','?')
    print(f'  {name:<15} role={role:<15} state={state:<12} lag={lag}')
" 2>/dev/null || echo "  (cluster API not yet responding — check logs)"

echo ""
info "Check streaming: curl -s http://localhost:8008/cluster | python3 -m json.tool"
info "Next: bash 06-setup-minio-replication.sh"
SCRIPT
chmod +x "${INSTALL_SCRIPTS_DIR}/05-deploy-dc2.sh"

# ── Install script 06: MinIO replication ──────────────────────────────────────
cat > "${INSTALL_SCRIPTS_DIR}/06-setup-minio-replication.sh" << 'SCRIPT'
#!/usr/bin/env bash
# =============================================================================
# 06-setup-minio-replication.sh
# Wire MinIO bidirectional site replication between DC1 and DC2.
# Run ONCE after both MinIO instances are healthy.
#
# This is a thin wrapper around dc-dr-setup/scripts/setup-minio-replication.sh
# Usage: bash 06-setup-minio-replication.sh
# =============================================================================
set -euo pipefail

INSTALL_DIR="${HOME}/dc-dr"
DC_DR="${INSTALL_DIR}/dc-dr-setup"
ENV_FILE="${DC_DR}/.env"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info() { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }

echo ""
echo "╔═══════════════════════════════════════════╗"
echo "║  Setup MinIO Site Replication             ║"
echo "╚═══════════════════════════════════════════╝"
echo ""

[ -f "${ENV_FILE}" ] || { echo "ERROR: .env not found. Run 04-deploy-dc1.sh first."; exit 1; }

set -a; source "${ENV_FILE}"; set +a

info "Verifying MinIO instances are healthy..."
DC1_OK=false; DC2_OK=false

curl -sf "http://localhost:9000/minio/health/live" &>/dev/null && DC1_OK=true || true
curl -sf "http://localhost:9002/minio/health/live" &>/dev/null && DC2_OK=true || true  # local-test
curl -sf "http://${DC2_IP}:9000/minio/health/live" &>/dev/null && DC2_OK=true || true  # two-VM

${DC1_OK} || warn "DC1 MinIO may not be healthy — replication will fail if so"
${DC2_OK} || warn "DC2 MinIO may not be healthy — ensure DC2 is running first"

info "Running MinIO site replication setup..."
bash "${DC_DR}/scripts/setup-minio-replication.sh"
SCRIPT
chmod +x "${INSTALL_SCRIPTS_DIR}/06-setup-minio-replication.sh"

# ── README-FIRST.txt ─────────────────────────────────────────────────────────
cat > "${BUNDLE_DIR}/README-FIRST.txt" << EOF
╔══════════════════════════════════════════════════════════════╗
║   DC/DR Stack — Airgap Bundle for RHEL 9                     ║
║   Built: ${DATE_TAG}                                         ║
╚══════════════════════════════════════════════════════════════╝

CONTENTS
────────
  images/dc-dr-images.tar.gz      All 8 Docker images (~3-5 GB)
  config/dc-dr-config.tar.gz      Compose files, configs, scripts, docs
  rpms/docker/                    Docker CE RPMs for RHEL 9 x86_64
  rpms/deps/                      System dependency RPMs
  pip-wheels/podman-compose/      podman-compose pip wheels (offline install)
  tools/jq                        Static jq binary (JSON processor)
  install-scripts/                Step-by-step automated install scripts
  BUNDLE-MANIFEST.txt             Full contents list with SHA256 checksums

QUICK START — TWO-VM PRODUCTION DEPLOYMENT
──────────────────────────────────────────
1. Copy this entire bundle to BOTH VMs (DC1 and DC2):
     scp -r airgap-bundle-${DATE_TAG}/ user@dc1-vm:/opt/dc-dr-bundle/
     scp -r airgap-bundle-${DATE_TAG}/ user@dc2-vm:/opt/dc-dr-bundle/

2. On DC1 VM — install Docker (Option A: Docker CE):
     cd /opt/dc-dr-bundle/install-scripts
     sudo bash 01-install-docker-rhel9.sh

   OR — use Podman (Option B, pre-installed on RHEL 9):
     sudo bash 02-install-podman-compose.sh

3. On DC1 VM — load images:
     bash 03-load-images.sh

4. On DC1 VM — deploy DC1 stack:
     bash 04-deploy-dc1.sh     ← follow prompts to set DC1_IP, passwords

5. On DC2 VM — repeat steps 2-3, then:
     bash 05-deploy-dc2.sh     ← will clone from DC1 automatically

6. On DC1 VM — wire MinIO replication:
     bash 06-setup-minio-replication.sh

7. Verify everything:
     curl -s http://localhost:8008/cluster | python3 -m json.tool
     # All 3 members: leader + 2 replicas streaming, lag=0

FULL DOCUMENTATION
──────────────────
After extracting config/dc-dr-config.tar.gz, all docs are in:
  ~/dc-dr/dc-dr-setup/docs/

Key documents:
  13-airgap-rhel9-setup.md    ← RHEL 9 specific guide (start here)
  11-local-test-setup-runbook.md  ← Local single-VM test mode
  06-troubleshooting.md       ← Fixes for known issues
  07-enterprise-test-scenarios.md ← Full test suite

CONTAINER RUNTIME — DOCKER vs PODMAN
─────────────────────────────────────
Docker CE  (script 01) — Full docker + docker compose support.
                          Requires adding Docker CE RPMs.
                          Preferred if your org already uses Docker.

Podman     (script 02) — Built into RHEL 9 BaseOS (already installed).
                          Use podman-compose for compose files.
                          Red Hat's preferred runtime for RHEL.
                          No additional RPMs needed in most cases.

NETWORK PORTS REQUIRED BETWEEN DC1 AND DC2
───────────────────────────────────────────
  5010/TCP  — Patroni Raft peer communication
  8008/TCP  — Patroni REST API
  5432/TCP  — PostgreSQL (for cross-DC queries, optional)
  9000/TCP  — MinIO S3 API (site replication)

Open these ports in your firewall/security groups before deployment.

CREDENTIALS (defaults — change in .env before first start)
───────────────────────────────────────────────────────────
  PostgreSQL superuser:  postgres / <PATRONI_SUPERUSER_PASSWORD>
  MinIO admin:           <MINIO_ROOT_USER> / <MINIO_ROOT_PASSWORD>
  Grafana:               admin / admin  (change after first login)

SUPPORT
───────
Full docs: dc-dr-setup/docs/
Troubleshooting: dc-dr-setup/docs/06-troubleshooting.md
EOF

# =============================================================================
section "Step 8/8 — Copy tools and generate manifest"
# =============================================================================

step "Generating SHA256 checksums and manifest..."

MANIFEST="${BUNDLE_DIR}/BUNDLE-MANIFEST.txt"
cat > "${MANIFEST}" << EOF
DC/DR Airgap Bundle — RHEL 9 Edition
Generated : $(date -u '+%Y-%m-%d %H:%M:%S UTC')
Built by  : $(whoami)@$(hostname)

═══════════════════════════════════════════════════════════
Target OS : RHEL 9 / CentOS Stream 9 / Rocky Linux 9 (x86_64)
═══════════════════════════════════════════════════════════

DOCKER IMAGES BUNDLED
─────────────────────
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
STACK VERSIONS
──────────────
PostgreSQL         : 16 (Bookworm)
Patroni            : 3.3.0
DCS                : Built-in Raft (pysyncobj) — no etcd required
MinIO              : RELEASE.2025-05-24T17-08-30Z
MinIO Client (mc)  : RELEASE.2024-11-17T19-35-25Z  (bundled as Docker image)
Prometheus         : v2.52.0
Alertmanager       : v0.27.0
Grafana OSS        : 11.0.0
postgres_exporter  : v0.15.0

RPM PACKAGES (Docker CE — RHEL 9 x86_64)
──────────────────────────────────────────
EOF

ls "${RPMS_DOCKER}"/*.rpm 2>/dev/null | while read -r rpm; do
  echo "  $(basename "$rpm")" >> "${MANIFEST}"
done || echo "  (download failed — see README-FIRST.txt)" >> "${MANIFEST}"

cat >> "${MANIFEST}" << EOF

DEPENDENCY RPMS
───────────────
EOF

ls "${RPMS_DEPS}"/*.rpm 2>/dev/null | while read -r rpm; do
  echo "  $(basename "$rpm")" >> "${MANIFEST}"
done || echo "  (none bundled)" >> "${MANIFEST}"

cat >> "${MANIFEST}" << EOF

SHA256 CHECKSUMS
────────────────
EOF

find "${BUNDLE_DIR}" -type f \( -name "*.tar.gz" -o -name "*.rpm" -o -name "*.whl" -o -name "jq" \) \
  -exec sha256sum {} \; | sed "s|${BUNDLE_DIR}/||" >> "${MANIFEST}"

info "Manifest written: ${MANIFEST}"

# =============================================================================
# Final summary
# =============================================================================

echo ""
echo -e "${CYAN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║   Bundle complete!                                        ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo "  Location : ${BUNDLE_DIR}/"
echo ""
echo "  Contents :"
find "${BUNDLE_DIR}" -maxdepth 3 -type f | sort | while read -r f; do
  SIZE=$(du -sh "$f" 2>/dev/null | cut -f1)
  printf "    %-8s  %s\n" "${SIZE}" "${f#${REPO_ROOT}/}"
done

TOTAL=$(du -sh "${BUNDLE_DIR}" | cut -f1)
echo ""
echo "  Total size : ${TOTAL}"
echo ""
echo "  Transfer the bundle:"
echo "    scp -r ${BUNDLE_DIR}/ user@dc1-vm:/opt/dc-dr-bundle/"
echo "    scp -r ${BUNDLE_DIR}/ user@dc2-vm:/opt/dc-dr-bundle/"
echo ""
echo "  On each VM, start with:"
echo "    cd /opt/dc-dr-bundle/install-scripts"
echo "    sudo bash 01-install-docker-rhel9.sh   # Option A: Docker CE"
echo "    bash 03-load-images.sh                  # Load all images"
echo "    bash 04-deploy-dc1.sh                   # Start DC1 (on DC1 VM)"
echo "    bash 05-deploy-dc2.sh                   # Start DC2 (on DC2 VM)"
echo "    bash 06-setup-minio-replication.sh       # Wire MinIO (from DC1)"
echo ""
echo "  Full guide: config/dc-dr-config.tar.gz → dc-dr-setup/docs/13-airgap-rhel9-setup.md"
echo ""
