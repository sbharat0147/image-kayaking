#!/bin/bash
set -e

CONFIG_TEMPLATE="${1:-/etc/patroni/patroni.yml}"
RENDERED="/tmp/patroni-rendered.yml"

# Expand ${VAR} placeholders in the config using Python's os.path.expandvars.
# Patroni does not natively expand shell-style variables in its YAML config.
python3 - "$CONFIG_TEMPLATE" "$RENDERED" <<'PYEOF'
import os, sys
with open(sys.argv[1]) as f:
    content = f.read()
content = os.path.expandvars(content)
with open(sys.argv[2], 'w') as f:
    f.write(content)
PYEOF

exec patroni "$RENDERED"
