FROM postgres:16-bookworm

# Remove ALL apt source lists the base image ships with:
#   - pgdg.list         : apt.postgresql.org (403 on this VM)
#   - debian.sources    : DEB822-format file that adds bookworm-updates
# Then point to snapshot.debian.org (frozen 2025-06-01 snapshot) so
# package hashes never mismatch due to CDN mid-sync issues.
RUN rm -f /etc/apt/sources.list.d/pgdg.list \
          /etc/apt/sources.list.d/debian.sources \
    && printf '\
deb http://snapshot.debian.org/archive/debian/20250601T000000Z bookworm main\n\
deb http://snapshot.debian.org/archive/debian-security/20250601T000000Z bookworm-security main\n\
' > /etc/apt/sources.list \
    && echo 'Acquire::Check-Valid-Until "false";' \
       > /etc/apt/apt.conf.d/99snapshot \
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
