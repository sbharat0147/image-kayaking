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

# Pre-download the embedding model so container works fully offline
RUN python -c "from sentence_transformers import SentenceTransformer; SentenceTransformer('all-MiniLM-L6-v2')"

EXPOSE 8080

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8080"]
