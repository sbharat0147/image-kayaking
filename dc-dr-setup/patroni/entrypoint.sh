#!/bin/bash
set -e

CONFIG_TEMPLATE="${1:-/etc/patroni/patroni.yml}"
RENDERED="/tmp/patroni-rendered.yml"

# The volume is mounted at /home/postgres (parent), not at /home/postgres/data.
# This lets Patroni rename /home/postgres/data → /home/postgres/data.failed
# during reinit without hitting "Device or resource busy" on a mount point.
mkdir -p /home/postgres/raft /home/postgres/data
chmod 700 /home/postgres/data
chown -R postgres:postgres /home/postgres/

# Expand ${VAR} placeholders in the patroni config template.
# Patroni does not natively expand shell-style variables in its YAML.
python3 - "$CONFIG_TEMPLATE" "$RENDERED" <<'PYEOF'
import os, sys
with open(sys.argv[1]) as f:
    content = f.read()
content = os.path.expandvars(content)
with open(sys.argv[2], 'w') as f:
    f.write(content)
PYEOF

# Bootstrap-mode: on first boot (no PG data yet), if this node has
# bootstrap.initdb config (i.e., it is the designated primary/DC1),
# clear partner_addrs so it can form a 1-node Raft cluster and
# initialize PostgreSQL without waiting for other nodes.
#
# DC2 and witness don't have bootstrap.initdb, so they keep their
# partner_addrs and wait for DC1 to appear before joining.
#
# On subsequent starts (PG data already exists), partner_addrs are
# preserved so DC1 can rejoin the 3-node cluster after a failover.
if [ ! -f "/home/postgres/data/PG_VERSION" ]; then
    python3 - "$RENDERED" <<'PYEOF'
import sys
import yaml

with open(sys.argv[1]) as f:
    config = yaml.safe_load(f)

if config.get('bootstrap', {}).get('initdb'):
    config.setdefault('raft', {})['partner_addrs'] = []
    print("[entrypoint] First boot + initdb config found: starting as "
          "1-node Raft cluster for solo PostgreSQL bootstrap.", file=sys.stderr)

with open(sys.argv[1], 'w') as f:
    yaml.dump(config, f, default_flow_style=False, allow_unicode=True)
PYEOF
fi

# Use gosu (included in the postgres base image) to drop to postgres user.
# This preserves proper signal handling (PID 1 receives SIGTERM correctly).
exec gosu postgres patroni "$RENDERED"
