#!/usr/bin/env bash
# Quick health probe — run from either VM to see cluster state.

set -euo pipefail

: "${DC1_IP:?}" "${DC2_IP:?}"

echo "════ Patroni cluster state ════"
curl -s "http://${DC1_IP}:8008/cluster" | python3 -m json.tool 2>/dev/null || echo "DC1 Patroni unreachable"
echo ""
curl -s "http://${DC2_IP}:8008/cluster" | python3 -m json.tool 2>/dev/null || echo "DC2 Patroni unreachable"

echo ""
echo "════ etcd leader ════"
curl -s "http://${DC1_IP}:2379/v3/maintenance/status" | python3 -m json.tool 2>/dev/null || echo "DC1 etcd unreachable"

echo ""
echo "════ MinIO health ════"
curl -sf "http://${DC1_IP}:9000/minio/health/live" && echo "DC1 MinIO: OK" || echo "DC1 MinIO: DOWN"
curl -sf "http://${DC2_IP}:9000/minio/health/live" && echo "DC2 MinIO: OK" || echo "DC2 MinIO: DOWN"

echo ""
echo "════ Replication lag (requires psql on PATH) ════"
psql -h "${DC2_IP}" -U postgres -c \
  "SELECT now() - pg_last_xact_replay_timestamp() AS replica_lag;" \
  2>/dev/null || echo "Cannot query DC2 PG replica lag"
