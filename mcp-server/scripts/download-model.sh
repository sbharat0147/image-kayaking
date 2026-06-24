#!/usr/bin/env bash
# Download the sentence-transformers embedding model on an internet-connected machine.
# Run this ONCE from mcp-server/ before building the Docker image.
#
# Usage:
#   cd mcp-server/
#   bash scripts/download-model.sh

set -euo pipefail

MODEL="all-MiniLM-L6-v2"
DEST="models/sentence-transformers_${MODEL}"

mkdir -p "${DEST}/1_Pooling"

BASE="https://huggingface.co/sentence-transformers/${MODEL}/resolve/main"

echo "Downloading sentence-transformers/${MODEL} → ${DEST}/"
echo "(SSL verification disabled for corporate proxy)"
echo ""

download() {
  local file="$1"
  local out="${DEST}/${file}"
  echo "  GET ${file}"
  wget -q --no-check-certificate -O "${out}" "${BASE}/${file}" \
    && echo "      OK ($(du -sh "$out" | cut -f1))" \
    || echo "      FAILED — skipping"
}

# Core model files
download "config.json"
download "tokenizer_config.json"
download "tokenizer.json"
download "vocab.txt"
download "special_tokens_map.json"
download "sentence_bert_config.json"
download "modules.json"

# Weights — try safetensors first, fall back to pytorch_model.bin
echo "  GET model.safetensors"
wget -q --no-check-certificate -O "${DEST}/model.safetensors" \
  "${BASE}/model.safetensors" \
  && echo "      OK ($(du -sh "${DEST}/model.safetensors" | cut -f1))" \
  || {
    echo "      safetensors not found, trying pytorch_model.bin..."
    wget -q --no-check-certificate -O "${DEST}/pytorch_model.bin" \
      "${BASE}/pytorch_model.bin" \
      && echo "      OK ($(du -sh "${DEST}/pytorch_model.bin" | cut -f1))" \
      || echo "      FAILED"
  }

# Pooling config
download "1_Pooling/config.json"

echo ""
echo "Files in ${DEST}:"
find "${DEST}" -type f | sort | while read -r f; do
  printf "  %-50s %s\n" "${f#$DEST/}" "$(du -sh "$f" | cut -f1)"
done

# Verify the critical file exists
if [ ! -f "${DEST}/config.json" ] || [ ! -s "${DEST}/config.json" ]; then
  echo ""
  echo "ERROR: config.json missing or empty — download failed."
  exit 1
fi

WEIGHT_OK=false
[ -s "${DEST}/model.safetensors" ] && WEIGHT_OK=true
[ -s "${DEST}/pytorch_model.bin" ] && WEIGHT_OK=true

if [ "${WEIGHT_OK}" = "false" ]; then
  echo ""
  echo "ERROR: No model weights found (model.safetensors or pytorch_model.bin) — download failed."
  exit 1
fi

echo ""
echo "Model ready. Now build the image:"
echo "  sudo docker compose up -d --build mcp-server"
