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

# Copy pre-downloaded embedding model (downloaded on build machine via download-model.sh)
# If the models/ directory doesn't exist the COPY is skipped (BuildKit behaviour).
COPY models/ /app/models/

# Tell sentence-transformers to use the local copy — no Hugging Face download at runtime
ENV SENTENCE_TRANSFORMERS_HOME=/app/models

EXPOSE 8080

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8080"]
