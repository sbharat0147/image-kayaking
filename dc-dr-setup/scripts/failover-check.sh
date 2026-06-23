#!/usr/bin/env bash
# Quick health probe — run from either VM to see cluster state.
# Usage: DC1_IP=<ip> DC2_IP=<ip> ./scripts/failover-check.sh

set -euo pipefail

: "${DC1_IP:?DC1_IP not set}" "${DC2_IP:?DC2_IP not set}"

echo "════ Patroni cluster state (DC1 view) ════"
curl -s "http://${DC1_IP}:8008/cluster" | python3 -m json.tool 2>/dev/null \
  || echo "DC1 Patroni unreachable"

echo ""
echo "════ Patroni cluster state (DC2 view) ════"
curl -s "http://${DC2_IP}:8009/cluster" | python3 -m json.tool 2>/dev/null \
  || echo "DC2 Patroni unreachable"

echo ""
echo "════ Primary endpoint check ════"
DC1_PRIMARY=$(curl -s -o /dev/null -w "%{http_code}" "http://${DC1_IP}:8008/primary")
DC2_PRIMARY=$(curl -s -o /dev/null -w "%{http_code}" "http://${DC2_IP}:8009/primary")
echo "DC1 /primary: HTTP ${DC1_PRIMARY}  (200=primary, 503=not primary)"
echo "DC2 /primary: HTTP ${DC2_PRIMARY}  (200=primary, 503=not primary)"

echo ""
echo "════ MinIO health ════"
curl -sf "http://${DC1_IP}:9000/minio/health/live" && echo "DC1 MinIO: OK" || echo "DC1 MinIO: DOWN"
curl -sf "http://${DC2_IP}:9002/minio/health/live" && echo "DC2 MinIO: OK" || echo "DC2 MinIO: DOWN"

echo ""
echo "════ Replication lag ════"
psql -h "${DC1_IP}" -p 5432 -U postgres \
  -c "SELECT client_addr, state, (sent_lsn - replay_lsn) AS lag_bytes FROM pg_stat_replication;" \
  2>/dev/null || echo "Cannot query DC1 PG replication state"
