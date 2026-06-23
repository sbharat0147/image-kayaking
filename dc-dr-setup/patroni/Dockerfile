# Stage 1: Download patroni wheels using the Python image.
# pip --trusted-host bypasses the corporate SSL inspection proxy's cert check.
# Wheels are saved to /wheels so stage 2 can install fully offline.
FROM python:3.11-slim-bookworm AS wheel-builder

RUN pip download --no-cache-dir \
    --trusted-host pypi.org \
    --trusted-host files.pythonhosted.org \
    --trusted-host pypi.python.org \
    "patroni[etcd3]==3.3.0" \
    "psycopg2-binary==2.9.9" \
    -d /wheels

# Stage 2: Final image — postgres base (all PG binaries + libs already inside).
# Copy Python runtime from stage 1 image and install wheels offline (no network).
FROM postgres:16-bookworm

COPY --from=wheel-builder /usr/local/lib/python3.11  /usr/local/lib/python3.11
COPY --from=wheel-builder /usr/local/bin/python3.11  /usr/local/bin/python3.11
COPY --from=wheel-builder /usr/local/bin/python3     /usr/local/bin/python3
COPY --from=wheel-builder /usr/local/bin/pip3        /usr/local/bin/pip3
COPY --from=wheel-builder /usr/local/bin/pip         /usr/local/bin/pip
COPY --from=wheel-builder /wheels                    /wheels

RUN pip3 install --no-index --find-links=/wheels \
        "patroni[etcd3]" psycopg2-binary \
    && rm -rf /wheels

RUN mkdir -p /etc/patroni /var/log/pgbackrest \
    && chown postgres:postgres /etc/patroni /var/log/pgbackrest

USER postgres
EXPOSE 5432 8008
CMD ["patroni", "/etc/patroni/patroni.yml"]
