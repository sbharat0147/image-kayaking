#!/usr/bin/env bash
# Verify the latest pgBackRest backup is intact.
# Schedule via cron: 0 6 * * * /path/to/backup-verify.sh

set -euo pipefail

echo "==> pgBackRest backup info:"
docker exec postgres-dc1 pgbackrest --stanza=main info

echo ""
echo "==> Running backup check (reads manifest, does not restore):"
docker exec postgres-dc1 pgbackrest --stanza=main check

echo ""
echo "==> Latest backup timestamp:"
docker exec postgres-dc1 pgbackrest --stanza=main info --output=json \
  | python3 -c "
import json,sys
data = json.load(sys.stdin)
for s in data:
    for b in s.get('backup',[]):
        print(b['label'], b['timestamp']['stop'])
" 2>/dev/null || echo "Could not parse backup JSON"
