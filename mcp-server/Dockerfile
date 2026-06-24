FROM python:3.11-slim-bookworm AS builder

WORKDIR /build

# Download wheels offline-capable (corporate proxy friendly)
COPY requirements.txt .
RUN pip download \
    --no-cache-dir \
    --trusted-host pypi.org \
    --trusted-host files.pythonhosted.org \
    --trusted-host pypi.python.org \
    -r requirements.txt \
    -d /wheels


FROM python:3.11-slim-bookworm

WORKDIR /app

# Install from pre-downloaded wheels — no internet needed at image-build time
COPY --from=builder /wheels /wheels
RUN pip install \
    --no-index \
    --find-links=/wheels \
    --no-cache-dir \
    fastapi uvicorn[standard] httpx pydantic pydantic-settings \
    sentence-transformers numpy \
    && rm -rf /wheels

# Copy application
COPY app/ ./app/
COPY tools/ ./tools/

# Copy pre-downloaded embedding model (downloaded on build machine via download-model.sh).
# Run  bash scripts/download-model.sh  before building — build fails if model is missing.
COPY models/sentence-transformers_all-MiniLM-L6-v2 /app/models/sentence-transformers_all-MiniLM-L6-v2
RUN test -f /app/models/sentence-transformers_all-MiniLM-L6-v2/config.json || \
    { echo "ERROR: embedding model files missing — run bash scripts/download-model.sh first"; exit 1; }

# Tell sentence-transformers to use the local copy — block ALL outbound HF calls
ENV SENTENCE_TRANSFORMERS_HOME=/app/models \
    HF_HUB_OFFLINE=1 \
    TRANSFORMERS_OFFLINE=1 \
    HF_DATASETS_OFFLINE=1

EXPOSE 8080

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8080"]
