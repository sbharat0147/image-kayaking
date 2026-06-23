# Stage 1: Download wheels from PyPI.
# --trusted-host bypasses the corporate SSL inspection proxy's cert check.
FROM python:3.11-slim-bookworm AS wheel-builder

RUN pip download --no-cache-dir \
    --trusted-host pypi.org \
    --trusted-host files.pythonhosted.org \
    --trusted-host pypi.python.org \
    "patroni[raft]==3.3.0" \
    "psycopg2-binary==2.9.9" \
    -d /wheels

# Stage 2: Final image — postgres base (all PG binaries + libs already inside).
FROM postgres:16-bookworm

# Copy Python runtime + shared library from stage 1. Install wheels offline.
COPY --from=wheel-builder /usr/local/lib/python3.11           /usr/local/lib/python3.11
COPY --from=wheel-builder /usr/local/lib/libpython3.11.so.1.0 /usr/local/lib/libpython3.11.so.1.0
COPY --from=wheel-builder /usr/local/bin/python3.11           /usr/local/bin/python3.11
COPY --from=wheel-builder /usr/local/bin/python3              /usr/local/bin/python3
COPY --from=wheel-builder /usr/local/bin/pip3                 /usr/local/bin/pip3
COPY --from=wheel-builder /usr/local/bin/pip                  /usr/local/bin/pip
COPY --from=wheel-builder /wheels                             /wheels

RUN ldconfig \
    && pip3 install --no-index --find-links=/wheels \
        "patroni[raft]" psycopg2-binary \
    && rm -rf /wheels

RUN mkdir -p /etc/patroni /home/postgres/raft \
    && chown -R postgres:postgres /etc/patroni /home/postgres/raft

# Entrypoint: expands ${VAR} in patroni.yml then calls patroni directly.
# Overrides the postgres base image's docker-entrypoint.sh which conflicts
# with Patroni's own bootstrap process.
COPY entrypoint.sh /usr/local/bin/patroni-entrypoint.sh
RUN chmod +x /usr/local/bin/patroni-entrypoint.sh

USER postgres
EXPOSE 5432 8008 5010
ENTRYPOINT ["/usr/local/bin/patroni-entrypoint.sh"]
CMD ["/etc/patroni/patroni.yml"]
