#!/bin/bash
set -e

CONFIG_TEMPLATE="${1:-/etc/patroni/patroni.yml}"
RENDERED="/tmp/patroni-rendered.yml"

# Docker volumes are created as root. Fix ownership so postgres user
# can write to the data and raft directories.
chown -R postgres:postgres /home/postgres/ 2>/dev/null || true
mkdir -p /home/postgres/raft /home/postgres/data
chown -R postgres:postgres /home/postgres/raft /home/postgres/data

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

# Use gosu (included in the postgres base image) to drop to postgres user.
# This preserves proper signal handling (PID 1 receives SIGTERM correctly).
exec gosu postgres patroni "$RENDERED"
