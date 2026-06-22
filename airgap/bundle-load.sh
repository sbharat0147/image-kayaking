#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# bundle-load.sh
# Run this on EACH AIRGAPPED VM after extracting the bundle.
# It verifies checksums, loads Docker images, installs project files,
# and makes all scripts executable.
#
# Usage (run as a user in the docker group):
#   tar -xzf airgap-bundle-<date>.tar.gz
#   bash bundle/bundle-load.sh
#
# Options:
#   --skip-verify   Skip sha256 checksum verification (faster, not recommended)
#   --dc1 | --dc2   Set which datacenter role this VM plays (prompts if omitted)
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

BUNDLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGES_DIR="${BUNDLE_DIR}/images"
INSTALL_DIR="${HOME}/dc-dr"

SKIP_VERIFY=false
THIS_DC=""

for arg in "$@"; do
    case $arg in
        --skip-verify) SKIP_VERIFY=true ;;
        --dc1) THIS_DC=dc1 ;;
        --dc2) THIS_DC=dc2 ;;
    esac
done

echo "════════════════════════════════════════════════════"
echo " Airgap Bundle Loader"
echo " Bundle : ${BUNDLE_DIR}"
echo " Install: ${INSTALL_DIR}"
echo "════════════════════════════════════════════════════"
echo ""

# ── Sanity checks ─────────────────────────────────────────────────────────
command -v docker >/dev/null || { echo "ERROR: docker not installed on this VM."; exit 1; }

if ! docker info >/dev/null 2>&1; then
    echo "ERROR: Cannot connect to Docker daemon."
    echo "       Add your user to the docker group: sudo usermod -aG docker \$USER"
    echo "       Then log out and back in."
    exit 1
fi

# ── Determine DC role ─────────────────────────────────────────────────────
if [[ -z "${THIS_DC}" ]]; then
    echo "Which datacenter role does this VM play?"
    select role in dc1 dc2; do
        THIS_DC="${role}"
        break
    done
fi
echo "DC role: ${THIS_DC}"
echo ""

# ── Verify checksums ──────────────────────────────────────────────────────
if [[ "${SKIP_VERIFY}" == "false" ]]; then
    echo "[1/4] Verifying image checksums..."
    (cd "${IMAGES_DIR}" && sha256sum --check "${BUNDLE_DIR}/images.sha256")
    echo "  All checksums OK."
else
    echo "[1/4] Skipping checksum verification (--skip-verify)."
fi
echo ""

# ── Load Docker images ────────────────────────────────────────────────────
echo "[2/4] Loading Docker images..."
echo ""
LOADED=0
for tar_file in "${IMAGES_DIR}"/*.tar; do
    [[ -f "${tar_file}" ]] || continue
    FNAME="$(basename "${tar_file}")"
    echo "  → loading ${FNAME}"
    docker load -i "${tar_file}"
    LOADED=$((LOADED + 1))
done
echo ""
echo "  Loaded ${LOADED} image(s)."
echo ""

# ── Install project files ─────────────────────────────────────────────────
echo "[3/4] Installing project configs to ${INSTALL_DIR}..."
mkdir -p "${INSTALL_DIR}"
cp -r "${BUNDLE_DIR}/configs/dc-dr-setup/." "${INSTALL_DIR}/"
chmod +x "${INSTALL_DIR}/scripts/"*.sh
chmod +x "${INSTALL_DIR}/minio/"*.sh
echo "  Done."
echo ""

# ── mc binary (MinIO client) ──────────────────────────────────────────────
# mc is shipped as a Docker image (minio/mc). Create a wrapper so it's
# usable from the host shell without a separate binary download.
echo "[4/4] Installing mc wrapper..."
MC_WRAPPER="/usr/local/bin/mc"
sudo tee "${MC_WRAPPER}" > /dev/null <<'WRAPPER'
#!/usr/bin/env bash
# Thin wrapper: runs mc from the bundled minio/mc Docker image
exec docker run --rm -it \
    --network host \
    -v "${HOME}/.mc:/root/.mc" \
    "minio/mc:RELEASE.2024-06-13T22-53-53Z" "$@"
WRAPPER
sudo chmod +x "${MC_WRAPPER}"
echo "  mc wrapper written to ${MC_WRAPPER}"
echo ""

# ── Summary ───────────────────────────────────────────────────────────────
echo "════════════════════════════════════════════════════"
echo " Load complete on ${THIS_DC^^}"
echo ""
echo " Project files : ${INSTALL_DIR}/"
echo ""
echo " Next steps:"
echo "   1. Copy .env.example to .env and fill in all values:"
echo "        cp ${INSTALL_DIR}/.env.example ${INSTALL_DIR}/.env"
echo "        nano ${INSTALL_DIR}/.env"
echo ""
echo "   2. Start the stack:"
if [[ "${THIS_DC}" == "dc1" ]]; then
echo "        docker compose -f ${INSTALL_DIR}/docker-compose.dc1.yml \\"
echo "          --env-file ${INSTALL_DIR}/.env up -d"
else
echo "        docker compose -f ${INSTALL_DIR}/docker-compose.dc2.yml \\"
echo "          --env-file ${INSTALL_DIR}/.env up -d"
fi
echo ""
echo "   3. (DC1 only, after both DCs are up) Wire MinIO site replication:"
echo "        source ${INSTALL_DIR}/.env"
echo "        bash ${INSTALL_DIR}/minio/mc-site-replication.sh"
echo ""
echo "   See AIRGAP-GUIDE.md for the full step-by-step."
echo "════════════════════════════════════════════════════"
