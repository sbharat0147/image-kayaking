FROM postgres:16-bookworm

# The postgres base image ships /etc/apt/sources.list.d/pgdg.list which
# points to apt.postgresql.org. If that host is unreachable (403/firewall),
# apt-get update fails. We don't need the repo — postgres binaries are
# already installed in the base image — so drop it before updating.
RUN rm -f /etc/apt/sources.list.d/pgdg.list \
    && apt-get update && apt-get install -y --no-install-recommends \
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
