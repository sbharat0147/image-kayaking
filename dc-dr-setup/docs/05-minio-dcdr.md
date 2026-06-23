# MinIO DC/DR — Setup & Testing

MinIO Site Replication creates an active-active bidirectional replication
between DC1 and DC2. Any bucket, object, IAM policy, or user created on
either site is automatically replicated to the other.

---

## Prerequisites

- Both MinIO instances running and healthy
- Same `MINIO_ROOT_USER` and `MINIO_ROOT_PASSWORD` on both sites
- Network connectivity between DC1:9000 and DC2:9000 (or 9002 in local-test)
- `mc` (MinIO Client) available — use the bundled container or install binary

---

## 1. Configure mc Aliases

### Using mc Docker container (airgap-safe, no install needed)

```bash
source dc-dr-setup/.env

# DC1 MinIO (local-test: port 9000, two-VM: port 9000 on DC1 host)
docker run --rm --network host minio/mc:RELEASE.2024-11-17T19-35-25Z \
  alias set dc1 http://${DC1_IP}:9000 ${MINIO_ROOT_USER} ${MINIO_ROOT_PASSWORD}

# DC2 MinIO (local-test: port 9002, two-VM: port 9000 on DC2 host)
docker run --rm --network host minio/mc:RELEASE.2024-11-17T19-35-25Z \
  alias set dc2 http://${DC1_IP}:9002 ${MINIO_ROOT_USER} ${MINIO_ROOT_PASSWORD}
```

### Using local mc binary

```bash
source dc-dr-setup/.env
mc alias set dc1 http://${DC1_IP}:9000 ${MINIO_ROOT_USER} ${MINIO_ROOT_PASSWORD}
mc alias set dc2 http://${DC1_IP}:9002 ${MINIO_ROOT_USER} ${MINIO_ROOT_PASSWORD}

# Verify connectivity
mc admin info dc1
mc admin info dc2
```

---

## 2. Enable Site Replication

Run once. Order does not matter — either site can be listed first.

```bash
mc admin replicate add dc1 dc2
```

Expected output:
```
Requested sites were configured for replication successfully.
```

---

## 3. Verify Replication Status

```bash
mc admin replicate info dc1
```

Look for:
- Both site names listed
- `replication status: Enabled`
- No errors

---

## Test Suite

### Test 1 — Bucket replication DC1 → DC2

```bash
# Create bucket on DC1
mc mb dc1/app-data

# Verify it appears on DC2 (should be near-instant)
mc ls dc2/ | grep app-data
# Expected: app-data bucket listed
```

### Test 2 — Object replication DC1 → DC2

```bash
# Upload an object on DC1
echo "dc-dr test object $(date)" > /tmp/test-object.txt
mc cp /tmp/test-object.txt dc1/app-data/test-object.txt

# Read from DC2
mc cat dc2/app-data/test-object.txt
# Expected: dc-dr test object <timestamp>

# Verify object metadata matches
mc stat dc1/app-data/test-object.txt
mc stat dc2/app-data/test-object.txt
# Expected: same size, same ETag (content hash)
```

### Test 3 — Bidirectional: DC2 → DC1

```bash
# Write on DC2
echo "written from dc2 $(date)" > /tmp/dc2-object.txt
mc cp /tmp/dc2-object.txt dc2/app-data/dc2-object.txt

# Read from DC1 (should replicate within seconds)
mc cat dc1/app-data/dc2-object.txt
# Expected: written from dc2 <timestamp>
```

### Test 4 — IAM / Policy replication

```bash
# Create a user on DC1
mc admin user add dc1 appuser StrongPass123

# Verify user exists on DC2
mc admin user list dc2 | grep appuser
# Expected: appuser listed
```

### Test 5 — Object deletion replication

```bash
# Delete object on DC1
mc rm dc1/app-data/test-object.txt

# Verify it's gone from DC2
mc ls dc2/app-data/ | grep test-object.txt
# Expected: no output (object removed)
```

### Test 6 — DC1 MinIO failure simulation

```bash
# Stop DC1 MinIO
docker compose -p dc1 -f dc-dr-setup/docker-compose.dc1.yml stop minio

# Confirm DC2 MinIO still serving data
mc ls dc2/app-data/
mc cat dc2/app-data/dc2-object.txt
# Expected: all data accessible from DC2

# Write new data to DC2 during DC1 outage
echo "written during dc1 outage" > /tmp/during-outage.txt
mc cp /tmp/during-outage.txt dc2/app-data/during-outage.txt

# Restore DC1 MinIO
docker compose -p dc1 -f dc-dr-setup/docker-compose.dc1.yml up -d minio
sleep 15

# Verify the object written during DC1 outage is now on DC1
mc cat dc1/app-data/during-outage.txt
# Expected: written during dc1 outage
# MinIO auto-heals missed writes when the site reconnects
```

### Test 7 — Large object replication

```bash
# Create a 100 MB test file
dd if=/dev/urandom bs=1M count=100 | base64 > /tmp/large-object.txt

# Upload to DC1
mc cp /tmp/large-object.txt dc1/app-data/large-object.txt

# Check replication lag for large objects
mc admin replicate backlog dc1
# Expected: shows backlog count and size; decreases to 0 once replicated
```

---

## Monitoring Replication Health

```bash
# Overall replication status
mc admin replicate info dc1

# Replication backlog (objects pending sync)
mc admin replicate backlog dc1

# Per-bucket replication status
mc replicate ls dc1/app-data

# Reset stuck replication (emergency use)
mc admin replicate resync start dc1 --site dc2
mc admin replicate resync status dc1
```

---

## MinIO Console (Web UI)

| Site | URL | Credentials |
|---|---|---|
| DC1 | http://localhost:9001 | MINIO_ROOT_USER / MINIO_ROOT_PASSWORD |
| DC2 | http://localhost:9003 | same credentials |

In the Console: **Settings → Site Replication** shows replication health,
bandwidth usage, and backlog in real time.

---

## Troubleshooting MinIO Replication

| Symptom | Cause | Fix |
|---|---|---|
| `replicate add` fails with auth error | Credentials mismatch between sites | Ensure both sites use identical MINIO_ROOT_USER and MINIO_ROOT_PASSWORD |
| Objects not replicating | Network between sites blocked | Verify port 9000 (or 9002) open between DC1 and DC2 |
| Replication backlog growing | High write rate or slow link | Check `mc admin replicate backlog dc1`; replication catches up automatically |
| Site shows `offline` in replicate info | MinIO on that site unreachable | Restart the MinIO container; replication resumes automatically |
| `mc admin replicate add` returns error about existing config | Site replication already enabled | Run `mc admin replicate info dc1` to view existing config |
