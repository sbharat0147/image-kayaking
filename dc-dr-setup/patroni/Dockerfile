FROM postgres:16-bookworm

# Use bookworm (Debian 12) — trixie-pgdg does not exist yet in the pgdg repo.
# psycopg2-binary and patroni[etcd3] ship pre-compiled wheels so gcc/libpq-dev
# are not needed, keeping the image smaller.
RUN apt-get update && apt-get install -y --no-install-recommends \
        python3 python3-pip curl pgbackrest \
    && pip3 install --no-cache-dir --break-system-packages \
        "patroni[etcd3]==3.3.0" \
        "psycopg2-binary==2.9.9" \
    && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /etc/patroni /var/log/pgbackrest \
    && chown postgres:postgres /etc/patroni /var/log/pgbackrest

USER postgres
EXPOSE 5432 8008
CMD ["patroni", "/etc/patroni/patroni.yml"]
