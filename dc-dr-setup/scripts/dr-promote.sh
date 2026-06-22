#!/usr/bin/env bash
# Emergency DR promotion script — run on DC2 when DC1 is completely down.
# This triggers a Patroni failover to make pg-dc2 the new primary.

set -euo pipefail

: "${DC2_IP:?DC2_IP not set in environment}"

echo "WARNING: This will promote DC2 PostgreSQL to primary."
echo "Only run this if DC1 is confirmed dead and will NOT come back online immediately."
read -rp "Type 'PROMOTE' to continue: " confirm
[[ "$confirm" == "PROMOTE" ]] || { echo "Aborted."; exit 1; }

echo ""
echo "==> Triggering Patroni failover to pg-dc2..."
docker exec postgres-dc2 patronictl -c /etc/patroni/patroni.yml failover pg-cluster \
  --master pg-dc1 --candidate pg-dc2 --force

echo ""
echo "==> New cluster state:"
docker exec postgres-dc2 patronictl -c /etc/patroni/patroni.yml list

echo ""
echo "==> Updating local /etc/hosts to point pg.internal to DC2..."
# Remove any existing pg.internal entry and add DC2
sudo sed -i '/pg\.internal/d' /etc/hosts
echo "${DC2_IP}  pg.internal" | sudo tee -a /etc/hosts

echo ""
echo "Promotion complete. Update your app's DB_HOST to ${DC2_IP} (or pg.internal)."
echo "MinIO DC2 is already available at http://${DC2_IP}:9000"
echo ""
echo "IMPORTANT: When DC1 comes back, run 'patronictl reinit pg-cluster pg-dc1'"
echo "to re-join it as a replica (do NOT start it standalone or you'll split-brain)."
