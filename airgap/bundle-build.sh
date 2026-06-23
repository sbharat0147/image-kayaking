#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# bundle-build.sh
# Run this on an INTERNET-CONNECTED machine (your laptop or a build host).
# It builds/pulls every required Docker image, saves them as .tar files,
# copies all project configs, and packs everything into a single archive.
#
# Output: ./airgap-bundle-<date>.tar.gz  (~2-4 GB)
#
# Requirements: docker, bash >= 4, tar, sha256sum
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DATE="$(date +%Y%m%d)"
BUNDLE_DIR="${SCRIPT_DIR}/bundle"
IMAGES_DIR="${BUNDLE_DIR}/images"
BUNDLE_NAME="airgap-bundle-${DATE}.tar.gz"

PATRONI_DOCKERFILE="${REPO_ROOT}/dc-dr-setup/patroni/Dockerfile"
PATRONI_IMAGE="local/patroni:3.3.0"

echo "════════════════════════════════════════════════════"
echo " Airgap Bundle Builder"
echo " Repo : ${REPO_ROOT}"
echo " Out  : ${SCRIPT_DIR}/${BUNDLE_NAME}"
echo "════════════════════════════════════════════════════"
echo ""

# ── Sanity checks ─────────────────────────────────────────────────────────
command -v docker    >/dev/null || { echo "ERROR: docker not found"; exit 1; }
command -v tar       >/dev/null || { echo "ERROR: tar not found"; exit 1; }
command -v sha256sum >/dev/null || { echo "ERROR: sha256sum not found (install coreutils)"; exit 1; }

# ── Prepare workspace ─────────────────────────────────────────────────────
rm -rf "${BUNDLE_DIR}"
mkdir -p "${IMAGES_DIR}"

# ── Step 1: Build Patroni image (no official image on Docker Hub) ─────────
echo "[1/5] Building local images from Dockerfiles..."
echo "      patroni: ${PATRONI_DOCKERFILE}"
docker build \
    --tag "${PATRONI_IMAGE}" \
    --file "${PATRONI_DOCKERFILE}" \
    "${REPO_ROOT}/dc-dr-setup/patroni/"
echo "  Built ${PATRONI_IMAGE}."
echo ""

# ── Step 2: Pull & save all images ────────────────────────────────────────
echo "[2/5] Pulling and saving Docker images..."
echo ""

IMAGE_LIST="${SCRIPT_DIR}/image-list.txt"
declare -a SAVED_IMAGES=()

while IFS= read -r line; do
    # skip comments and blank lines
    [[ "$line" =~ ^#.*$ || -z "${line// /}" ]] && continue

    IMAGE=$(echo "$line" | awk '{print $1}')
    FILENAME=$(echo "$line" | awk '{print $2}')

    if [[ "${IMAGE}" == local/* ]]; then
        # Local image was already built above — just save it
        echo "  → saving local image  ${IMAGE}"
    else
        echo "  → pulling  ${IMAGE}"
        docker pull "${IMAGE}"
        echo "  → saving   ${FILENAME}"
    fi

    docker save "${IMAGE}" -o "${IMAGES_DIR}/${FILENAME}"
    SAVED_IMAGES+=("${FILENAME}")
    echo ""
done < "${IMAGE_LIST}"

echo "  Saved ${#SAVED_IMAGES[@]} images."
echo ""

# ── Step 3: Copy project configs ──────────────────────────────────────────
echo "[3/5] Copying project files..."

CONFIGS_DIR="${BUNDLE_DIR}/configs"
mkdir -p "${CONFIGS_DIR}"

# Copy dc-dr-setup (strip .env and secrets if accidentally present)
rsync -a --exclude='.env' --exclude='*.pem' --exclude='*.key' \
    "${REPO_ROOT}/dc-dr-setup/" "${CONFIGS_DIR}/dc-dr-setup/"

# Copy airgap scripts themselves (needed on target for load + deploy)
cp "${SCRIPT_DIR}/bundle-load.sh"   "${BUNDLE_DIR}/"
cp "${SCRIPT_DIR}/image-list.txt"   "${BUNDLE_DIR}/"
mkdir -p "${BUNDLE_DIR}/patches"
cp "${SCRIPT_DIR}/patches/"*.yml    "${BUNDLE_DIR}/patches/"

echo "  Done."
echo ""

# ── Step 4: Checksums ─────────────────────────────────────────────────────
echo "[4/5] Generating checksums..."
(cd "${IMAGES_DIR}" && sha256sum ./*.tar > "${BUNDLE_DIR}/images.sha256")
echo "  Written to bundle/images.sha256"
echo ""

# ── Step 5: Pack everything ───────────────────────────────────────────────
echo "[5/5] Packing bundle..."
OUTPUT="${SCRIPT_DIR}/${BUNDLE_NAME}"
tar -czf "${OUTPUT}" -C "${SCRIPT_DIR}" bundle/
BUNDLE_SIZE=$(du -sh "${OUTPUT}" | cut -f1)
echo ""
echo "════════════════════════════════════════════════════"
echo " Bundle ready: ${OUTPUT}"
echo " Size        : ${BUNDLE_SIZE}"
echo ""
echo " Next steps:"
echo "   1. Transfer ${BUNDLE_NAME} to each airgapped VM:"
echo "        scp ${BUNDLE_NAME} user@dc1-vm:~/"
echo "        scp ${BUNDLE_NAME} user@dc2-vm:~/"
echo "   2. On each VM run:"
echo "        tar -xzf ${BUNDLE_NAME}"
echo "        bash bundle/bundle-load.sh"
echo "════════════════════════════════════════════════════"
