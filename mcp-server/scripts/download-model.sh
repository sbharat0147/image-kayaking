#!/usr/bin/env bash
# Download the sentence-transformers embedding model on an internet-connected machine.
# Run this ONCE from mcp-server/ before building the Docker image.
#
# Usage:
#   cd mcp-server/
#   bash scripts/download-model.sh

set -euo pipefail

MODEL="all-MiniLM-L6-v2"
# sentence-transformers caches models as "sentence-transformers_<model-name>"
DEST="models/sentence-transformers_${MODEL}"

mkdir -p "${DEST}"

BASE_URL="https://huggingface.co/sentence-transformers/${MODEL}/resolve/main"

FILES=(
  "config.json"
  "tokenizer_config.json"
  "tokenizer.json"
  "vocab.txt"
  "special_tokens_map.json"
  "sentence_bert_config.json"
  "modules.json"
  "pytorch_model.bin"
  "1_Pooling/config.json"
)

mkdir -p "${DEST}/1_Pooling"

echo "Downloading sentence-transformers/${MODEL} to ${DEST}/ ..."
echo "(SSL verification disabled — corporate proxy environment)"
echo ""

for file in "${FILES[@]}"; do
  out="${DEST}/${file}"
  url="${BASE_URL}/${file}"
  echo "  GET ${file}"
  wget --no-check-certificate -q -O "${out}" "${url}" || {
    echo "  WARN: failed to download ${file} — skipping"
  }
done

echo ""
echo "Model files in ${DEST}/:"
find "${DEST}" -type f | sort

echo ""
echo "Done. Now build the image:"
echo "  sudo docker build -t local/mcp-server:1.0.0 ."
