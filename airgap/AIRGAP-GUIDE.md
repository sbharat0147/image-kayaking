# Airgap Deployment Guide — PostgreSQL + MinIO DC/DR Stack

This guide covers taking the full DC/DR solution from an internet-connected
build host to two VMs that have **no outbound internet access**.

---

## Directory Layout

```
airgap/
├── AIRGAP-GUIDE.md                  ← this file
├── image-list.txt                   ← pinned Docker image versions
├── bundle-build.sh                  ← run on internet machine to create bundle
├── bundle-load.sh                   ← run on each airgapped VM to install
└── patches/
    ├── docker-compose.dc1.airgap.yml  ← Docker Compose overlay (no-pull + tweaks)
    └── docker-compose.dc2.airgap.yml
```

After `bundle-build.sh` runs it also produces (gitignored):

```
airgap/bundle/
├── images/          ← Docker image tarballs
├── images.sha256    ← checksums
├── configs/         ← copy of dc-dr-setup/
├── bundle-load.sh   ← copy of loader
└── patches/         ← copy of overlays
```

---

## Prerequisites

### Build host (internet-connected)

| Requirement | Notes |
|-------------|-------|
| Docker ≥ 24 | Must be able to `docker pull` from Docker Hub |
| bash ≥ 4 | Ships with any modern Linux/macOS |
| rsync | `apt install rsync` / `brew install rsync` |
| sha256sum | part of `coreutils` |
| ~8 GB free disk | ~2–4 GB images + overhead |

### Airgapped VMs (both DC1 and DC2)

| Requirement | Notes |
|-------------|-------|
| Docker ≥ 24 | Install **before** network is removed, or use offline pkg below |
| docker compose plugin | `apt install docker-compose-plugin` |
| bash ≥ 4 | |
| ~10 GB free disk | Images + data volumes |
| Inter-DC TCP | Ports 2379, 2380, 5432, 8008, 9000 open between the two VMs |

#### Installing Docker offline

If Docker itself is not yet on the airgapped VM, download the static binaries
from an internet machine and carry them in the bundle:

```bash
# On internet machine — pick the right arch (amd64 / arm64)
ARCH=x86_64
DOCKER_VER=27.0.3
curl -fsSL "https://download.docker.com/linux/static/stable/${ARCH}/docker-${DOCKER_VER}.tgz" \
    -o docker-static.tgz
# Add docker-static.tgz to your bundle manually before packing
```

On the airgapped VM:
```bash
tar -xzf docker-static.tgz
sudo cp docker/* /usr/local/bin/
sudo dockerd &   # or set up a systemd unit
```

---

## Step 1 — Build the Bundle (internet machine)

```bash
git clone <this-repo> image-kayaking
cd image-kayaking/airgap
bash bundle-build.sh
```

Output: `airgap/airgap-bundle-<YYYYMMDD>.tar.gz`

The script:
1. Pulls every image in `image-list.txt` (pinned versions).
2. Saves each as a `.tar` file.
3. Copies all project configs (no secrets — `.env` is excluded).
4. Writes `images.sha256` checksums.
5. Packs everything into one `.tar.gz`.

---

## Step 2 — Transfer to Both VMs

```bash
# Adjust user/hostname to match your environment
scp airgap-bundle-<date>.tar.gz user@dc1-vm:~/
scp airgap-bundle-<date>.tar.gz user@dc2-vm:~/
```

If scp is unavailable (fully airgapped), use physical media:
```bash
# Write to USB
tar -czf - airgap-bundle-<date>.tar.gz | dd of=/dev/sdX bs=4M status=progress
# On target VM
dd if=/dev/sdX bs=4M | tar -xzf -
```

---

## Step 3 — Load on DC1 VM

```bash
tar -xzf airgap-bundle-<date>.tar.gz
bash bundle/bundle-load.sh --dc1
```

This will:
- Verify all image checksums.
- `docker load` every image.
- Copy project files to `~/dc-dr/`.
- Install an `mc` wrapper at `/usr/local/bin/mc`.

---

## Step 4 — Configure DC1 `.env`

```bash
cp ~/dc-dr/.env.example ~/dc-dr/.env
nano ~/dc-dr/.env
```

Fill in at minimum:

```dotenv
DC1_IP=<actual DC1 VM IP>
DC2_IP=<actual DC2 VM IP>
THIS_DC=dc1
POSTGRES_PASSWORD=<strong password>
PATRONI_SUPERUSER_PASSWORD=<strong password>
PATRONI_REPLICATION_PASSWORD=<strong password>
MINIO_ROOT_USER=minioadmin
MINIO_ROOT_PASSWORD=<strong password>
```

---

## Step 5 — Start DC1 Stack

```bash
cd ~/dc-dr

docker compose \
  -f docker-compose.dc1.yml \
  -f ~/image-kayaking/airgap/patches/docker-compose.dc1.airgap.yml \
  --env-file .env \
  up -d

# Verify all containers came up
docker compose -f docker-compose.dc1.yml ps
```

Check Patroni is running:
```bash
curl -s http://localhost:8008/leader | python3 -m json.tool
```

---

## Step 6 — Load and Start DC2

Repeat Steps 3–5 on DC2, using `--dc2` and `THIS_DC=dc2`:

```bash
# DC2 VM
tar -xzf airgap-bundle-<date>.tar.gz
bash bundle/bundle-load.sh --dc2

cp ~/dc-dr/.env.example ~/dc-dr/.env
nano ~/dc-dr/.env   # same values as DC1 but THIS_DC=dc2

docker compose \
  -f docker-compose.dc2.yml \
  -f ~/image-kayaking/airgap/patches/docker-compose.dc2.airgap.yml \
  --env-file .env \
  up -d
```

After DC2 starts, Patroni will automatically pull WAL from DC1 and sync the
replica. Confirm with:

```bash
curl -s http://<DC2_IP>:8008/replica
```

---

## Step 7 — Wire MinIO Site Replication

Run **once, from DC1** after both MinIO instances are healthy:

```bash
source ~/dc-dr/.env
bash ~/dc-dr/minio/mc-site-replication.sh
```

Verify with:
```bash
mc admin replicate info dc1
```

Both sites will now sync all buckets bidirectionally, including the
`pgbackrest-archive` bucket that holds WAL archives and base backups.

---

## Step 8 — Create First pgBackRest Backup

```bash
# On DC1 VM
# Create the bucket in MinIO first
mc mb dc1/pgbackrest-archive

# Initialise stanza and run full backup
docker exec postgres-dc1 pgbackrest --stanza=main stanza-create
docker exec postgres-dc1 pgbackrest --stanza=main --type=full backup

# Confirm backup landed
docker exec postgres-dc1 pgbackrest --stanza=main info
```

---

## Step 9 — Verify the Full Stack

```bash
source ~/dc-dr/.env
bash ~/dc-dr/scripts/failover-check.sh
```

Expected output:
- Patroni: one primary (dc1), one replica (dc2).
- Both MinIO instances: OK.
- Replica lag: a few seconds or zero.

---

## Updating the Bundle

When you need to update an image version or add new configs:

1. Edit `image-list.txt` (pin the new version).
2. Re-run `bundle-build.sh` — it rebuilds everything from scratch.
3. Transfer the new `.tar.gz` and re-run `bundle-load.sh` on each VM.
   - `docker load` of an already-loaded image is safe; it just replaces the tag.

---

## Troubleshooting

### `docker load` fails with "no space left"

```bash
df -h /var/lib/docker
# If full, prune old images first
docker image prune -a
```

### Patroni can't find etcd

Check that ports 2379/2380 are open **between the two VMs**:
```bash
nc -zv <DC2_IP> 2379
```
Patroni needs to reach etcd on the other DC to establish quorum.

### MinIO site replication reports "site not reachable"

Check port 9000 between DCs:
```bash
curl -v http://<DC2_IP>:9000/minio/health/live
```

Both MinIO instances must have **identical** `MINIO_ROOT_USER` /
`MINIO_ROOT_PASSWORD`. Site replication will refuse to configure otherwise.

### etcd split-brain (2 nodes, DC link down)

With 2 etcd nodes, losing the inter-DC link means neither node has quorum.
Patroni will demote both to replica mode (safe — no split-brain writes).
Recovery: restore the network, etcd re-elects, Patroni re-promotes DC1.

For a more resilient setup, add a third etcd node (lightweight arbiter) on
either VM or a separate host.

---

## Image Version Bump Checklist

When updating any image in `image-list.txt`:

- [ ] Update version in `image-list.txt`
- [ ] Update the same version in `docker-compose.dc1.yml` and `docker-compose.dc2.yml`
- [ ] Update the `mc` wrapper version in `bundle-load.sh` (line with `minio/mc:`)
- [ ] Re-run `bundle-build.sh` and test the new bundle in a staging VM
- [ ] Commit the version bump with message `chore: bump <image> to <version>`
