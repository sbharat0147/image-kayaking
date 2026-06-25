# PostgreSQL HA Concepts — Observations & Lessons Learned

**Audience:** Anyone new to PostgreSQL high-availability who wants to understand
*why* things are configured the way they are, and what real errors look like
and mean. Every section here was triggered by an actual issue encountered
during testing and setup.

---

## 1. What is a WAL Timeline?

### The concept

PostgreSQL writes every change to a sequential log called the
**Write-Ahead Log (WAL)**. The WAL is the single source of truth — even if
the server crashes mid-transaction, PostgreSQL can replay the WAL to reach
a consistent state.

A **timeline** is like a branch in this log. It starts at 1 when a cluster
is first initialised. Every time a replica is **promoted to primary**
(a failover), PostgreSQL creates a new timeline. This is how it distinguishes
"the history before the failover" from "the history after".

```
Timeline 1:  [initial cluster boot] ──► [writes] ──► [failover!]
Timeline 2:                                              └──► [DC2 becomes primary] ──► [writes]
Timeline 3:                                                                               └──► [DC1 promoted back]
```

### Why it matters

A replica can only stream WAL from a primary whose timeline is **directly
reachable** from its own. If a replica is at timeline 4 and the primary is
at timeline 7 with three intermediate promotions the replica missed, it
cannot simply start streaming — it would be reading WAL that belongs to a
different history branch.

### What you see in the logs

```
ERROR: replication slot "pg_dc2" does not exist
FATAL: could not start WAL streaming
```

This error means: PostgreSQL tried to open a streaming connection to the
primary, but the replication slot set up for it (which tracks the WAL
position) doesn't exist or is at an incompatible position.

### The fix

Patroni handles this automatically with **pg_rewind** (see section 3).
If pg_rewind cannot bridge the gap, Patroni runs a full **pg_basebackup**
(a fresh copy of the primary's data directory). In both cases no operator
action is required — but the node's data directory must be cleared so
Patroni can reinitialise it.

---

## 2. What is a Replication Slot?

### The concept

A **replication slot** is a pointer that the primary maintains for each
replica. It tells PostgreSQL:
> "Do not discard any WAL segments that this replica has not yet consumed."

Without slots, if a replica falls behind (e.g. it was offline for an hour),
PostgreSQL might rotate away the WAL segments it needs, making streaming
impossible. With slots, those segments are retained until the replica
catches up.

### Slot name convention

Patroni names slots after the member: hyphens become underscores.
`pg-dc2` → slot name `pg_dc2`. `pg-witness` → `pg_witness`.

### Checking slots

```bash
# See all slots and whether a replica is actively consuming them
psql -U postgres -c "SELECT slot_name, slot_type, active, restart_lsn FROM pg_replication_slots;"
```

| Column | Meaning |
|---|---|
| `slot_name` | Which replica this slot is for |
| `active` | `t` = replica is currently streaming, `f` = replica is disconnected |
| `restart_lsn` | The oldest WAL position the primary must keep for this slot |

### The danger of inactive slots

If `active = f` and the replica stays offline for a long time, the slot
keeps accumulating WAL on the primary disk indefinitely. In production, set
`max_slot_wal_keep_size` to cap this and alert when a slot has been inactive
too long.

### Slot creation

Patroni creates slots automatically on the primary when a replica registers
with the DCS (Distributed Configuration Store). The slot for `pg_dc2` is
created by DC1's Patroni when DC2 first joins the cluster — not by DC2
itself. This is why DC2 must be able to communicate with DC1's Patroni
process (not just PostgreSQL) at startup.

---

## 3. What is pg_rewind?

### The concept

`pg_rewind` is a PostgreSQL utility that synchronises a node's data directory
with a target primary **without doing a full re-copy of all data**.

It works by:
1. Finding the point in the WAL where the two timelines diverged
2. Copying only the files that changed between that point and now
3. Setting up streaming replication from the new primary

This is much faster than a full `pg_basebackup` for large databases.

### When Patroni uses it

After a failover:
- DC2 becomes the new primary (timeline advances)
- DC1 comes back online with data from the old timeline
- Patroni detects the divergence and calls `pg_rewind` on DC1
- DC1 rewinds to the point it last agreed with DC2, then streams forward

### Requirements

`pg_rewind` requires that **`wal_log_hints = on`** (or data checksums) was
set *before* the divergence occurred. This is set in our config. If it was
not set, pg_rewind cannot work and Patroni falls back to `pg_basebackup`.

### Configuration in our setup

```yaml
# patroni.dc1.yml / bootstrap.dcs.postgresql
use_pg_rewind: true    # enable pg_rewind on rejoin
check_timeline: true   # verify timeline before streaming; trigger rewind if mismatched
failsafe_mode: true    # prevent primary from stepping down if it loses DCS contact
```

---

## 4. What is connect_address and Why Does it Matter?

### The concept

Every Patroni node publishes two **connect addresses** to the DCS
(the shared configuration store):

1. `restapi.connect_address` — where other Patroni nodes and operators
   can reach this node's REST API (health checks, leader election, etc.)
2. `postgresql.connect_address` — where PostgreSQL clients and replicas
   can connect to this node's database

These addresses are what other nodes in the cluster use to communicate.
They must be **reachable from the other nodes** — not from the local machine.

### The local-test pitfall

In local-test mode both DC1 and DC2 run on the same physical host.
A naive configuration sets `connect_address: 127.0.0.1:5432` for DC1.

From the host machine's perspective, `127.0.0.1:5432` → DC1. ✓
From inside DC2's Docker container, `127.0.0.1:5432` → DC2 itself. ✗

When DC2's Patroni reads the leader's address from the DCS and tries to
run `pg_basebackup`, it connects to its own container instead of DC1:

```
pg_basebackup: error: connection to server at "127.0.0.1", port 5432 failed: Connection refused
ERROR: Error when fetching backup: pg_basebackup exited with code=1
```

### The fix

Each node must advertise its **Docker network IP** (not the host IP) as
its connect_address. We assign static IPs on the shared `patroni-cluster`
Docker network:

| Node | Static container IP | What it advertises |
|---|---|---|
| DC1 | 172.30.0.10 | `connect_address: 172.30.0.10:5432` |
| DC2 | 172.30.0.20 | `connect_address: 172.30.0.20:5432` |
| Witness | 172.30.0.30 | `connect_address: 172.30.0.30:5432` |

These IPs are reachable from any container on the `patroni-cluster` network,
so DC2 can correctly basebackup from `172.30.0.10:5432` (DC1).

Host port-mapped access (`localhost:5432`, `localhost:5433`) still works for
operator psql commands — the port mapping handles the translation.

### In production (two-VM mode)

On separate VMs, there is no shared Docker network. Each node uses its
VM's actual network IP (`${DC1_IP}`, `${DC2_IP}`) as the connect_address.
This is set via the `PATRONI_CONNECT_IP` environment variable:

| Environment | `PATRONI_CONNECT_IP` value |
|---|---|
| Local-test (docker-compose) | Hardcoded to 172.30.0.10/20/30 in compose file |
| Production (two-VM) | Set to the VM's actual IP in `.env.production` |

---

## 5. The Stale Volume / Timeline Mismatch Problem

### What happened

During local development, the test cycle was:
1. Start DC1 fresh (timeline 1)
2. Run tests, trigger failovers (timeline advances to 2, 3, …)
3. `docker compose down` (without `-v`) — volumes persist
4. Start DC1 fresh again (new cluster, timeline resets to 1 on a NEW cluster identity)
5. Start DC2 — its volume has data from a completely different cluster at timeline 4

Result: DC2 cannot stream because its data belongs to a different cluster's history.

### Why this only happens in local testing

In production:
- DC1 is never torn down and rebuilt from scratch unless the entire cluster is decommissioned
- Timeline advances only on failover, not on container restart
- DC2's volume always represents the same cluster's history as DC1

### Symptoms

```
ERROR: replication slot "pg_dc2" does not exist
active: f   (slot exists but no replica connected)
lag: 33554832   (32 MB behind, not decreasing)
```

Check the timelines:
```bash
curl -s http://localhost:8008/cluster | python3 -m json.tool
# DC1 timeline: 7
# DC2 timeline: 4   ← mismatch!
```

### Fix for local testing

Always tear down with `-v` between fresh test runs to remove stale volumes:

```bash
docker compose -p dc2 -f docker-compose.dc2-local.yml --env-file .env down -v
docker compose -p dc1 -f docker-compose.dc1.yml --env-file .env down -v
```

### Fix for production (automatic)

With `check_timeline: true` and `use_pg_rewind: true` in Patroni config,
any timeline mismatch on a node rejoining the cluster is handled
automatically:

1. Patroni detects the timeline gap
2. Attempts `pg_rewind` to fast-forward the diverged node
3. If `pg_rewind` fails (WAL already recycled), falls back to `pg_basebackup`
4. Replica comes back clean with no operator intervention required

---

## 6. What is Raft DCS?

### The concept

A cluster of PostgreSQL nodes needs a **shared brain** to answer questions like:
- Who is the current primary?
- Is the primary alive?
- Should we promote a replica?

This shared brain is called the **Distributed Configuration Store (DCS)**.
Traditional setups use etcd or ZooKeeper as an external DCS. Our setup uses
**Patroni's built-in Raft** (`pysyncobj`) — no external service needed.

### Raft quorum

Raft requires a **majority** of nodes to agree before making any change.
With 3 nodes (DC1, DC2, witness):
- 2 out of 3 must agree → **quorum = 2**
- If DC1 goes down → DC2 + witness = 2 → quorum met → DC2 promotes ✓
- If DC2 goes down → DC1 + witness = 2 → quorum met → DC1 stays primary ✓
- If both DC1 and DC2 go down → only witness remains → no quorum → no changes made ✓ (safe)

The witness node runs a full Patroni/PostgreSQL process but is tagged
`nofailover: true` — it participates in Raft voting but never becomes primary.

### Raft peer addresses

Raft peers communicate using **static IPs on the patroni-cluster network**:
```yaml
raft:
  self_addr: 172.30.0.10:5010   # DC1
  partner_addrs:
    - 172.30.0.20:5010          # DC2
    - 172.30.0.30:5010          # witness
```

Using static IPs (not container names) avoids Docker DNS returning a wrong
network's IP when containers are attached to multiple networks.

---

## 7. Summary: The Connect_Address Fix and Production Impact

| Issue | Root cause | Impact | Fix |
|---|---|---|---|
| `pg_basebackup: Connection refused` | `connect_address: 127.0.0.1` published to DCS — resolves to wrong container | DC2/witness can never clone from DC1 | Use static container IP via `PATRONI_CONNECT_IP` |
| Timeline mismatch on DC2 start | Stale volume from previous test run | DC2 stuck, not streaming | `down -v` in local test; `check_timeline + pg_rewind` in production |
| Slot `active: f` | DC2 not streaming due to timeline mismatch | WAL accumulates on DC1 disk | Fix the streaming issue; set `max_slot_wal_keep_size` in production |
| `wal_keep_size` too small | 128 MB recycled during long DC2 outage | pg_rewind fails, needs full basebackup | Increased to 1024 MB; Patroni falls back to basebackup automatically |
