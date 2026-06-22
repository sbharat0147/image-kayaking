FROM postgres:16

# Install Patroni with etcd3 support + dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
        python3 python3-pip python3-dev \
        gcc libpq-dev curl \
    && pip3 install --no-cache-dir --break-system-packages \
        "patroni[etcd3]==3.3.0" \
        "psycopg2-binary==2.9.9" \
    && apt-get purge -y gcc python3-dev libpq-dev \
    && apt-get autoremove -y \
    && rm -rf /var/lib/apt/lists/*

# pgBackRest for WAL archiving
RUN apt-get update && apt-get install -y --no-install-recommends pgbackrest \
    && rm -rf /var/lib/apt/lists/*

# Patroni config directory
RUN mkdir -p /etc/patroni /var/log/pgbackrest \
    && chown postgres:postgres /etc/patroni /var/log/pgbackrest

USER postgres
EXPOSE 5432 8008
CMD ["patroni", "/etc/patroni/patroni.yml"]
