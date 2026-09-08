# MultiversX Deep-History Observing Squad — Operations Guide

Working notes for the mainnet deep-history squad. Written so a rebuild — here or on
another machine — is a straight line instead of a re-investigation.

**Repo:** `github.com/foxsyai/mvx-deep-history-squad`
**First built:** 1 August 2026 (mainnet epoch 2192 → 2193)
**Reference hardware:** Intel NUC-class box · 31 GB RAM · 12 threads · 3.6 TB NVMe

> Paths below assume the stock layout the install scripts create: nodes under
> `$HOME/elrond-nodes`, scripts under `$HOME/mx-chain-scripts`. Substitute your own
> user/host throughout.

---

## 1. What is running

| Component | Path | Port | Shard |
|---|---|---|---|
| node-0 | `~/elrond-nodes/node-0` | 8080 | 0 |
| node-1 | `~/elrond-nodes/node-1` | 8081 | 1 |
| node-2 | `~/elrond-nodes/node-2` | 8082 | 2 |
| node-3 | `~/elrond-nodes/node-3` | 8083 | metachain |
| proxy  | `~/elrond-proxy` | **8079** | — gateway |

Install scripts: `~/mx-chain-scripts` (`./script.sh` menu). Services: `elrond-node-{0..3}`,
`elrond-proxy`, all `enabled` at boot.

Query form:

```bash
curl "http://localhost:8079/address/<erd1...>?blockNonce=<N>"
```

Nonces are **per shard** — shard 1's height is not shard 0's. Ask the proxy for the
account with no `blockNonce` first; `data.blockInfo.nonce` tells you that shard's height.

---

## 2. The one thing to understand

Deep history does **not** come from `--operation-mode=historical-balances`.
It comes from a single setting:

```toml
[StateTriesConfig]
    AccountsStatePruningEnabled = false     # keeps intra-epoch state
```

…which is **already the stock default**. How far back that state is retained is bounded by:

```toml
[StoragePruning]
    ObserverCleanOldEpochsData     = true
    AccountsTrieCleanOldEpochsData = true
    NumEpochsToKeep                = 62     # ≈ 60 usable epochs / days
```

This is exactly how the public gateway serves 3 epochs of deep history — it just ships
`NumEpochsToKeep = 4`. Bigger number, longer window. Nothing else differs.

### Why we do NOT use `-operation-mode historical-balances`

From `mx-chain-go/common/operationmodes/historicalBalances.go` — the flag hard-forces:

```go
StoragePruning.ObserverCleanOldEpochsData     = false   // retention impossible
StoragePruning.AccountsTrieCleanOldEpochsData = false   // retention impossible
GeneralSettings.StartInEpochEnabled           = false   // ← disables fast bootstrap
StateTriesConfig.AccountsStatePruningEnabled  = false
DbLookupExtensions.Enabled                    = true
Preferences.FullArchive                       = true
```

Two consequences, both bad for us:

1. **Unbounded growth.** `NumEpochsToKeep` is dead — both cleanup flags are forced off.
   Storage grows forever (MultiversX quote 7.5 TB for genesis→2024).
2. **`StartInEpochEnabled = false` means a fresh node replays from GENESIS.** Measured on
   the reference hardware: ~2,200 rounds in 24 minutes against a chain at round 31.5M — about
   **239 days**. This is the trap that cost the most time during the build.

Without the flag, fast bootstrap works normally and a fresh node is synced in under an hour.

---

## 3. Fresh install — from a bare Ubuntu box

Target: ≥8 cores, ≥32 GB RAM, ≥1 TB NVMe (see §5 for sizing). Ordinary user with `sudo`;
do **not** run as root — `CUSTOM_USER` becomes the systemd service user.

### 3.1 Copy-paste block

```bash
# ---- 1. prerequisites (the script installs curl/jq itself, but needs git to clone) ----
sudo apt update && sudo apt install -y git curl jq

# ---- 2. get the official install scripts ----
git clone https://github.com/multiversx/mx-chain-scripts.git ~/mx-chain-scripts
cd ~/mx-chain-scripts

# ---- 3. configure ----
sed -i 's|^ENVIRONMENT=.*|ENVIRONMENT="mainnet"|'        config/variables.cfg
sed -i "s|^CUSTOM_HOME=.*|CUSTOM_HOME=\"$HOME\"|"        config/variables.cfg
sed -i "s|^CUSTOM_USER=.*|CUSTOM_USER=\"$USER\"|"        config/variables.cfg
sed -i 's|^NODE_EXTRA_FLAGS=.*|NODE_EXTRA_FLAGS=""|'     config/variables.cfg   # MUST stay empty — see §2
# Strongly recommended: your own GitHub token, or the install may hit API rate limits.
# sed -i 's|^GITHUBTOKEN=.*|GITHUBTOKEN="ghp_xxxxxxxx"|' config/variables.cfg

# ---- 4. install the squad (interactive; builds Go + node, ~15-30 min) ----
./script.sh observing_squad

# ---- 5. apply our customizations BEFORE first start (see §4 for why) ----
#    Public repo — no credentials needed
git clone https://github.com/foxsyai/mvx-deep-history-squad.git ~/mvx-deep-history
cp ~/mvx-deep-history/scripts/mvx-deephistory-apply.sh ~/
chmod +x ~/mvx-deephistory-apply.sh
~/mvx-deephistory-apply.sh

# ---- 6. start ----
./script.sh start
```

### 3.2 Notes

- `observing_squad` deploys **four observers (shards 0/1/2 + metachain) plus the proxy**,
  and **auto-generates observer keys**. The `VALIDATOR_KEYS` / `node-0.zip` business in the
  upstream README applies to *validators* — irrelevant here. Nothing to prepare.
- Ports come out as node-0..3 on `8080..8083`, proxy on `8079`.
- If you skip step 5, the squad still runs — it just behaves as a stock 3-epoch observing
  squad rather than a 60-epoch deep-history one.

### 3.3 What happens next

Each node fast-bootstraps to the current epoch — minutes for metachain, up to ~3 h for
shard 1 (largest state) — then retains state forward within the 62-epoch window.
**No archive downloads, no import-db, no two-phase seeding.**

Deep history is queryable from roughly the moment each node finishes bootstrapping, and the
window then grows until it hits 62 epochs and starts rolling.

> The MultiversX docs push you toward downloading daily archives. Those URLs are **not
> public** — `url_base = "https://..."` is redacted and you must request access via
> Discord/Telegram. You do not need them for "deep history from now on".

### 3.4 Confirm it worked

```bash
for n in 0 1 2 3; do p=$((8080+n)); printf "node-%s [%s]: " $n "$(systemctl is-active elrond-node-$n)"
  curl -s localhost:$p/node/status | jq -c 'if .data==null then {s:.error} else
    {ep:.data.metrics.erd_epoch_number, nonce:.data.metrics.erd_nonce,
     gap:(.data.metrics.erd_probable_highest_nonce-.data.metrics.erd_nonce)} end'; done
```

Want: four `active` nodes, a real epoch number, `gap` ≈ 0. **An `epoch` of `0` means it is
replaying from genesis — stop and read §2.** Then run the deep-history probe in §6.

---

## 4. After EVERY upgrade — run the apply script

**Order matters. Run it BEFORE starting the nodes.**

```bash
./script.sh upgrade_squad      # 1. upgrades; leaves nodes stopped, config/ reset to stock
~/mvx-deephistory-apply.sh     # 2. re-apply customizations  <-- BEFORE any start
./script.sh start              # 3. now safe to start
```

> **Why the order is not optional.** Stock `config.toml` ships
> `AccountsTrieCleanOldEpochsData = true` together with `NumEpochsToKeep = 4`. A node
> started on stock config will, at the next epoch boundary, prune the accounts trie down
> to **4 epochs** — destroying the whole retention window. There is no undo; you would
> rebuild it from scratch. Config is read **only at startup**, so a node already running
> on stock values keeps them until restarted.

`--restart` is only for changing settings on an already-running squad (it restarts nodes
sequentially). After an upgrade the nodes are already stopped, so plain invocation is right.

`phase2-when-ready.sh` is **not** part of this flow — it exists only for the
historical-balances edge case in §7 and is unused in the current setup.

Customizations do not survive upgrades, because:

What an upgrade actually does to your customizations:

| Item | Survives an upgrade? | Mechanism |
|---|---|---|
| `prefs.toml` — `NodeDisplayName`, `DestinationShardAsObserver`, `Identity` | ✅ **yes** | `upgrade` and `upgrade_squad` both copy it to `prefs.toml.save` before `update()` and `mv` it back after |
| `DbLookupExtensions.Enabled` | ✅ yes (`upgrade_squad` only) | explicit `sed` re-enabling it after `update()` |
| six `variables.cfg` fields incl. `NODE_EXTRA_FLAGS` | ✅ yes | `variables_backup` → `git reset --hard` → `variables_restore` |
| systemd units (log level, flags) | ✅ yes | upgrades never call `systemd()`; only a fresh install regenerates them |
| **`NumEpochsToKeep`** | ❌ **no** → back to `4` | `update()` overwrites `config.toml` wholesale |
| **`TrieOperationsDeadlineMilliseconds`** | ❌ no → back to `10000` | ditto |
| **`ObserverCleanOldEpochsData`** | ❌ no → back to `false` | ditto |
| **`AccountsTrieCleanOldEpochsData`** | ❌ no → back to `true` | ditto |
| **`AccountsTrieSkipRemovalCustomPattern`** | ❌ no → back to `"%50"` | ditto |

So the apply script exists for **`config.toml` only**. Everything else the scripts already
handle. The dangerous one is `NumEpochsToKeep` reverting to `4` — see the warning above.

| Action | What it resets |
|---|---|
| `script.sh upgrade` / `upgrade_squad` | all of `config/` via `cp -r <config-repo>/*`, then restores `prefs.toml` from its own backup |
| `script.sh github_pull` (option 14) | `git reset --hard HEAD` — discards every local edit to `mx-chain-scripts`, **except** the six `variables.cfg` fields, saved and restored around the reset |
| `script.sh observing_squad` | regenerates systemd units from `functions.cfg` (so re-apply log level after a *reinstall*, not after an upgrade) |

Consequences worth internalising:

- **`prefs.toml` → `OverridableConfigTomlValues` does not help.** That is the node's
  official mechanism for persisting config across upgrades, but `prefs.toml` is itself
  overwritten by `update()`. Dead end.
- **`variables.cfg`: these six fields DO survive** — `ENVIRONMENT`, `CUSTOM_HOME`,
  `CUSTOM_USER`, `NODE_KEYS_LOCATION`, `GITHUBTOKEN`, `NODE_EXTRA_FLAGS`. `github_pull`
  runs `variables_backup` → `git reset --hard` → `variables_restore`: the reset reverts the
  file, but those six values are stashed in `~/script-configs-backup/custom-variables` and
  `sed`-ed back in straight after (the temp file is then deleted, so that directory normally
  looks empty). This is why you never have to re-enter them.
  **But only those six, by name.** A new variable you add yourself — `MY_SETTING="x"` —
  is not in `variables_restore` and is silently lost. So `variables.cfg` is fine for
  `NODE_EXTRA_FLAGS` (our `""` persists) and useless as a home for anything new.
- `functions.cfg` gets **no** such protection — edits there are simply gone. That is why
  the apply script patches the generated systemd units directly rather than the template,
  and why it lives **outside** `mx-chain-scripts`, in `$HOME`.

What it enforces, per node:

| Setting | Value | Why |
|---|---|---|
| `TrieOperationsDeadlineMilliseconds` | `100000` | stock 10000 ms times out deep historical queries |
| `AccountsStatePruningEnabled` | `false` | **the** deep-history switch |
| `ObserverCleanOldEpochsData` | `true` | let the node delete old epoch DBs |
| `AccountsTrieCleanOldEpochsData` | `true` | let the node delete old trie data |
| `NumEpochsToKeep` | `62` | ≈60 usable epochs |
| `AccountsTrieSkipRemovalCustomPattern` | `""` | stock `"%50"` keeps every 50th epoch **forever**, defeating the storage ceiling |
| `DbLookupExtensions.Enabled` | `true` | tx/block lookup by hash |
| systemd `-log-level` | `*:INFO` | DEBUG dumps full SC payloads — 382 KB per 40 lines |
| systemd `-operation-mode` | *removed* | see §2 |
| `prefs.toml` → `NodeDisplayName` | `$NODE_DISPLAY_NAME` | optional convenience only — upgrades already preserve this (see table below). Useful to set it non-interactively on a fresh install, or to change it later across all four nodes at once |

Setting it once is remembered in `~/.mvx-deephistory.conf`; leave it unset and the script
does not touch `prefs.toml` at all:

```bash
NODE_DISPLAY_NAME=foxsy ~/mvx-deephistory-apply.sh
```

It is idempotent and fails loudly if upstream renames a key.

---

## 5. Storage

**Size the disk before you pick a retention window — this is the binding constraint.**

Measured on mainnet (a full-trie epoch directory, all four nodes):

| Node | Shard | Per epoch |
|---|---|---|
| node-0 | 0 | 3.7 GB |
| node-1 | 1 | **10.8 GB** ← dominates |
| node-2 | 2 | 3.2 GB |
| node-3 | metachain | 0.2 GB |
| | **total** | **≈ 17.6 GB / epoch** |

Steady state is simply `NumEpochsToKeep × 17.6 GB`:

| Retention | Disk needed | Minimum practical volume |
|---|---|---|
| 14 epochs | ~250 GB | 320 GB |
| 30 epochs | ~530 GB | 700 GB |
| 35 epochs | ~620 GB | 800 GB |
| **62 epochs** | **~1.1 TB** | 1.5 TB |

Add ~40 GB for OS, Go toolchain and logs, plus headroom — a full disk stops the nodes.
Shard 1 is roughly 3× shard 0, so do not extrapolate from shard 0 alone (I did initially,
and under-called 62 epochs by ~400 GB).

Empty epoch dirs are ~372 KB — the pruning storer pre-creates the whole window on start,
which is normal and harmless.

These are *rolling* figures: nothing is pruned until the window fills, so the first real
pruning event is `NumEpochsToKeep` days after install. Verify it plateaus then, rather
than assuming it will.

```bash
df -h /
for n in 0 1 2 3; do printf "node-%s: " $n; du -sh ~/elrond-nodes/node-$n/db | cut -f1; done
```

To change the window: edit `NUM_EPOCHS_TO_KEEP` in the apply script, re-run with `--restart`.

---

## 6. Verification

```bash
# All four synced?  want gap≈0, sync=0
for n in 0 1 2 3; do p=$((8080+n)); printf "node-%s: " $n
  curl -s localhost:$p/node/status | jq -c '{ep:.data.metrics.erd_epoch_number,
    nonce:.data.metrics.erd_nonce,
    gap:(.data.metrics.erd_probable_highest_nonce-.data.metrics.erd_nonce),
    sync:.data.metrics.erd_is_syncing}'; done
```

Deep-history probe — pick a real address from a recent block, then walk backwards:

```bash
NOW=$(curl -s localhost:8080/node/status | jq -r .data.metrics.erd_nonce)
A=$(curl -s "localhost:8080/block/by-nonce/$((NOW-40))?withTxs=true" \
    | jq -r '[..|.sender?|select(type=="string" and startswith("erd1"))]|unique|.[0]')
for N in $NOW $((NOW-5000)) $((NOW-25000)); do
  printf "  %s -> " $N
  curl -s "localhost:8080/address/$A?blockNonce=$N" \
    | jq -c 'if (.error//"")!="" then {ERR:.error} else {at:.data.blockInfo.nonce} end'
done
```

A healthy node returns `at` **equal to the nonce you asked for**. If it echoes the current
height instead, it is answering from live state and deep history is not working.

Outside the window you get `key not found` or `missing hash for header nonce` — a hard
error, **not** a silent fallback to current state. Handle that explicitly in clients.

---

## 7. Troubleshooting

**Build fails with `expected 'package', found 'EOF'`.** Go's caches are corrupt — in
practice this means an unclean shutdown (power loss) hit the box mid-upgrade. The files
still exist but are zero-length: the filesystem journalled the metadata and never flushed
the data. Confirm the shutdown, then measure the damage:

```bash
last -x reboot shutdown | head                     # reboot with no matching shutdown = unclean
journalctl --list-boots | tail -3
find ~/go/pkg/mod       -name '*.go' -size 0 | wc -l   # module cache
find ~/.cache/go-build  -type f      -size 0 | wc -l   # build cache
```

Purge **both**, then re-run the upgrade:

```bash
go clean -modcache
go clean -cache
cd ~/mx-chain-scripts && ./script.sh upgrade_squad
```

> Clearing only the module cache is the trap. The module files then look perfectly valid
> on disk — right byte counts, zero empty files — and the build *still* fails with the
> identical error, because Go is replaying truncated artifacts out of the **build** cache.
> On 2026-09-07 that cost an hour: 14,966 of 19,046 `.go` files were empty in `pkg/mod`,
> plus 319 zero-length entries in `.cache/go-build`. After both purges the node built in
> ~90 s.

**Node dies with `error while loading shared libraries: libvmexeccapi.so`.** The binary
links the wasmer libraries by **absolute path into the module cache**:

```bash
objdump -x ~/elrond-nodes/node-0/node | grep RUNPATH
#  .../go/pkg/mod/github.com/multiversx/mx-chain-vm-go@v1.5.48/wasmer2:...
```

So anything that wipes `$GOPATH/pkg` — `go clean -modcache`, or the scripts' own cleanup
path — instantly bricks the *already-installed* binary, even though nothing touched
`elrond-nodes/`. There is nothing to copy back and no `LD_LIBRARY_PATH` worth setting:
rebuild with `upgrade_squad`, which relinks against the freshly downloaded module. Until
then systemd will restart-loop the unit every 3 s (we caught one at 1,959 restarts).

**`apt upgrade` hangs forever on a desktop-flavoured node box.** Not a slow mirror — a
systemd job deadlock. On a machine that boots `graphical.target` with `quiet splash` but is
only ever driven over SSH, nothing dismisses the boot splash, so `plymouth --wait` never
returns and `plymouth-quit-wait.service` sits in `activating (start)` for the whole uptime.
That blocks `multi-user.target`, which blocks every queued service **start** job — so the
first dpkg postinst that restarts a service waits forever, holding the dpkg lock with the
upgrade half-applied.

```bash
systemctl list-jobs --no-pager        # plymouth-quit-wait "running", targets "waiting"
ps -eo pid,etimes,cmd | grep -E "[p]ostinst|[d]eb-systemd-invoke"
```

Unblock the machine — the queue drains instantly and dpkg continues on its own. **Do not
kill dpkg:**

```bash
sudo systemctl stop plymouth-quit-wait.service
sudo plymouth quit
sudo dpkg --configure -a          # finish anything left interrupted
```

Permanent fix, reversible and touching no bootloader config:

```bash
sudo systemctl mask plymouth-quit-wait.service
sudo systemctl reset-failed plymouth-quit-wait.service
```

> Related trap: **an SSH timeout during `apt-get upgrade` does not kill the remote dpkg.**
> It keeps running detached and keeps the lock. Check `pgrep -af dpkg` and wait it out
> rather than retrying, or you will fight the lock and risk a half-configured system. Run
> long upgrades detached in the first place: `setsid nohup ... > ~/upgrade.log 2>&1 &`.

**Node is at `epoch = 0` and crawling.** It is replaying from genesis. Check:

```bash
sudo journalctl -u elrond-node-0 -o cat | grep -a "fast bootstrap is disabled"
grep -E "ExecStart=" /etc/systemd/system/elrond-node-0.service | grep -v '#'
```

Cause is almost always `-operation-mode historical-balances` back in the unit (an upgrade
regenerated it from `functions.cfg`). Fix: `./mvx-deephistory-apply.sh --restart`.

**Genesis fallback when restarting into full-history mode.** If you *do* run the
historical-balances flag, `StartInEpochEnabled=false` means the node can only start from
storage. With a thin `db` it goes to the network, cannot fast-bootstrap, and drops to
epoch 0. Only switch modes once the node is **caught up to the tip**. `~/phase2-when-ready.sh`
implements that gate. Not needed in the current flagless setup.

**Journal eating the disk.** `prerequisites()` in `functions.cfg` appends
`SystemMaxUse=4000M` + `SystemMaxFileSize=800M` to `/etc/systemd/journald.conf` on *every*
run, so the file accumulates duplicate lines. Ours is pinned at `SystemMaxUse=2G`.

```bash
grep -nE "^[^#]" /etc/systemd/journald.conf     # expect exactly 3 lines
sudo journalctl --vacuum-size=500M
```

**Proxy returns `sending request error`** on a historical query — usually a nonce from the
wrong shard's range, not a fault. See §1.

---

## 8. Routine fleet maintenance

OS hygiene across every node machine — run **monthly**, and again after each mainnet
release once the nodes are on the new binary. Nothing here touches the chain config; it is
apt + kernel + a reboot, plus proof that every node came back and caught up.

`scripts/mvx-fleet-maint.sh` automates it:

```bash
./scripts/mvx-fleet-maint.sh survey     # read-only: what needs updating, are we all synced
./scripts/mvx-fleet-maint.sh maintain   # update -> upgrade -> autoremove -> reboot -> verify
./scripts/mvx-fleet-maint.sh report     # resource + sync table (disk / RAM / CPU / gap)
```

`survey` and `report` never write. `maintain` is the only mode that reboots.

### 8.1 Inventory lives outside this repo

The host list is **not** tracked here — this repo is public. Keep it at
`~/.mvx-fleet.hosts` (mode `600`), or point `MVX_FLEET_HOSTS` wherever you like:

```
# name              user@host           nodes
do-sh0              deploy@203.0.113.1  1
observing-squad     deploy@203.0.113.9  4
```

### 8.2 What it does per machine, and why

| Step | Command | Why it is written this way |
|---|---|---|
| 1 | `apt-get update` | — |
| 2 | `apt-get upgrade -y` with `--force-confold` | keeps your existing config files. Without it an unattended run either hangs on a conffile prompt or silently replaces a tuned config |
| 3 | `apt-get autoremove -y` | drops orphaned packages, mostly old kernels |
| 4 | `systemctl stop elrond-*` **before** reboot | closes LevelDB cleanly. A node killed mid-write is exactly how §7's corruption story starts |
| 5 | `shutdown -r now` | activates the kernel apt just installed |
| 6 | wait for SSH, then 90 s grace | nodes need a moment before `/node/status` is meaningful |
| 7 | probe every node | `gap = probable_highest - nonce`; want `gap≈0`, `syncing=0` |

`apt` and `apt-get` share one package database — running both is redundant, once is enough.

### 8.3 Order and safety

- **Do the machines one at a time**, or in small independent batches, and confirm each is
  back and synced before moving on. If one fails to return, stop the pass and investigate
  before rebooting anything else.
- **Check whether a node is actually in the consensus set before rebooting it.** A staked,
  eligible validator loses rating for downtime; a pure observer loses nothing. The node's
  own `erd_peer_type` is not sufficient — confirm against the network:

  ```bash
  KEY=$(curl -s localhost:8080/node/status | jq -r .data.metrics.erd_public_key_block_sign)
  curl -s localhost:8079/validator/statistics | jq --arg k "$KEY" '.data.statistics[$k] // "not in validator set"'
  ```

- **Never reboot a node that is mid trie-sync.** You throw away hours of shard-state sync
  for a reboot that can wait. Check `journalctl -u elrond-node-1 | grep "trie sync"` and
  let it finish first.
- Reboot flags survive: a box showing `*** System restart required ***` with weeks of
  uptime is running an *older kernel than the one installed*. Compare them:

  ```bash
  echo "running $(uname -r) / newest $(ls -1 /boot/vmlinuz-* | sed 's|.*vmlinuz-||' | sort -V | tail -1)"
  ```

### 8.4 The report

`report` emits a markdown table — disk free, RAM, load, and how many nodes are healthy:

| machine | os | kernel | uptime | disk free | ram | cpu load | nodes ok |
|---|---|---|---|---|---|---|---|
| do-sh0 | Ubuntu 22.04.5 LTS | 5.15.0-191 | 1 minute | 50G free / 97G (49% used) | 1.0Gi / 7.8Gi | 0.84 0.36 0.13 | 1/1 |

Watch the trend, not the snapshot: disk is the one that ends squads. See §5 — the
deep-history box grows at ~17.6 GB per epoch and a full disk stops the nodes. DigitalOcean's
per-droplet graphs cover CPU/RAM/IO history; this table is the cross-machine view it lacks.

---

## 9. Reference

- Deep-history docs: https://docs.multiversx.com/integrators/deep-history-squad/
- Operation modes: https://docs.multiversx.com/validators/node-operation-modes/
- Authoritative flag behaviour: `~/go/src/github.com/multiversx/mx-chain-go/common/operationmodes/historicalBalances.go`
- Mainnet genesis: `1596117600` = **2020-07-30 14:00 UTC**; epoch N starts genesis + N days.
  Daily-archive naming uses that date (`31-Jul-2026` = epoch 2192).

Initial deep-history floors from the 1 Aug 2026 build (these advance once the 62-epoch
window starts rolling):

| Shard | First queryable nonce |
|---|---|
| 0 | 31,548,153 |
| 1 | 31,551,730 |
| 2 | 31,556,509 |
| metachain | 31,543,224 |

### Housekeeping

- **`GITHUBTOKEN` in `variables.cfg` is optional — leave it empty.** Every repo the scripts
  touch (`mx-chain-scripts`, `mx-chain-go`, `mx-chain-*-config`) is public. The token only
  raises the GitHub API limit from 60 to 5000 requests/hour. Without it an install can stall
  with "API limit reached" on a busy or NATed IP — wait an hour and retry. That is a better
  trade than a plaintext credential sitting on disk.
- Helper script: `~/mvx-deephistory-apply.sh`. Settings persist in `~/.mvx-deephistory.conf`
  (retention, trie deadline, display name), so post-upgrade runs need no arguments.
- Backups the tooling leaves behind: `/root/elrond-unit-backups-*`, per-node
  `config/config.toml.bak-*` and `config/prefs.toml.bak-*`. Safe to delete once verified.
  If you ever back up `variables.cfg` while it still holds a token, delete that copy too.
