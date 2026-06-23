FROM postgres:16-bookworm

# Drop the pgdg repo (host is blocked) and replace the full sources.list
# with only bookworm stable + bookworm-security. bookworm-updates is prone
# to hash-sum mismatches during CDN mirror syncs and we don't need it.
RUN rm -f /etc/apt/sources.list.d/pgdg.list \
    && printf 'deb http://deb.debian.org/debian bookworm main\ndeb http://deb.debian.org/debian-security bookworm-security main\n' \
       > /etc/apt/sources.list \
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
