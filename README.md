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

**Box hard-resets during an upgrade, with nothing in the logs.** Suspect heat before
power. A software crash always leaves a trace; a hardware thermal cutoff (THERMTRIP) cuts
power with no chance to log, so the journal just *stops*. A 12-thread `go build` is the
heaviest load a node box ever sees, which is why upgrades — and only upgrades — trigger it.

```bash
cat /sys/devices/system/cpu/cpu0/thermal_throttle/package_throttle_count   # climbing at idle = bad
for z in /sys/class/thermal/thermal_zone*; do echo "$(cat $z/type) $(( $(cat $z/temp)/1000 ))C"; done
```

On two NUC10i7FNH boxes (15 W i7-10710U) the tells were 63-100 C at *idle* and thousands of
throttle events. Cleaning the fan and fins fixed idle temperature; a 4-thread load still
spiked to 91 C in 8 s — dried thermal paste.

**Cap power, not frequency.** `scripts/mvx-thermal-cap.sh` holds the package to a fixed
RAPL budget with turbo allowed, and sets the burst limit equal to the sustained one (the
stock 64 W bursts are what cause the spikes). The obvious alternative, `no_turbo=1`, pins
this CPU to its 1.1 GHz base clock: fine for 6 s rounds, but after Supernova (600 ms
rounds, 10x the blocks) it left both 12-core boxes at 96-99 % CPU and a multikey backup's
metachain falling behind. At 12 W with turbo: 1.5-2.4 GHz, plateau 61-72 C, and that
metachain went from 379 blocks behind to caught up in three minutes.

```bash
sudo install -m 755 scripts/mvx-thermal-cap.sh /usr/local/sbin/
printf "WATTS=12\nSAFE_WATTS=8\nHOT_C=88\n" | sudo tee /etc/default/mvx-thermal-cap
# mvx-thermal-cap.service runs `apply` at boot (RAPL limits reset every boot);
# mvx-thermal-watch.timer runs `watch` every 30 s and drops to SAFE_WATTS if HOT_C is hit
```

Find the budget empirically: run it for several minutes under real load and read the
plateau, not the first reading — thermal equilibrium on a NUC takes about a minute.

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
- **Know whether a node signs before you restart it — and don't trust the obvious check.**
  A validator loses rating for downtime; a pure observer loses nothing. Neither
  `erd_peer_type` nor `erd_public_key_block_sign` answers this for a **multikey** node: in
  multikey mode the node's own key is a throwaway, and it signs for the BLS keys in
  `config/allValidatorsKeys.pem`. Checking the node's own key against
  `/validator/statistics` reports "not a validator" for a host signing for 80 live keys —
  that exact mistake was made here in September 2026. Look at the files instead:

  ```bash
  grep -c "BEGIN PRIVATE KEY" ~/elrond-nodes/node-0/config/allValidatorsKeys.pem  # managed keys
  grep RedundancyLevel ~/elrond-nodes/node-0/config/prefs.toml                   # 0 main, 1+ backup
  ```

- **Multikey main/backup pairs: never down together.** A backup (`RedundancyLevel >= 1`)
  signs only while the main is silent. Upgrade or reboot all mains first, confirm each is
  *committing blocks* again (not merely `active` — a node needs ~20 s to rejoin consensus),
  and only then touch the backup. `maintain` walks the inventory top to bottom, so list mains
  before backups. Upgrade multikey hosts with **option 5, `upgrade_multikey`** — the scripts
  map it straight to `upgrade_squad`; plain `upgrade` skips re-enabling `DbLookupExtensions`.

- **Every node runs `-log-level *:INFO`, never DEBUG.** mx-chain-scripts' unit template
  hard-codes `-log-level *:DEBUG` (`config/functions.cfg`, the `systemd` function). Since
  Supernova that is ~14,000 lines/min per node against ~100 at INFO. On a 4-node squad the
  4 GB journal then holds about an hour, so yesterday's incident is already gone. On a
  power-capped NUC, journald alone took 12 % of a core. In September 2026 six of seven
  machines were at DEBUG. Upgrades (`upgrade`, `upgrade_multikey`, `upgrade_squad`) and
  `github_pull` leave the unit files alone. `install`, `add_node`, `observers` and
  `multikey` regenerate them at DEBUG. After any of those:

  ```bash
  ./scripts/mvx-fleet-maint.sh loglevel   # fix units; restart only non-INFO nodes, one at a time
  ```

  It restarts a multikey node only while another machine is healthy and signing for the
  same shard, and does nothing when every node is already at INFO. `maintain` fixes the
  units before its reboot; `survey` and `report` show each node's level and flag DEBUG.

  The journal's 4 GB cap is not the whole story. Ubuntu's rsyslog also copies every line
  into `/var/log/syslog`, which rotates only weekly and has no size cap. At DEBUG that
  reached 18–20 GB a week on the 4-node machines, and 45 GB of `/var/log` in total. After
  fixing the level, reclaim it with a forced rotation. It needs a root-owned config with
  the global `su` line, or logrotate refuses:

  ```bash
  g=/tmp/lr-rsyslog-only.conf
  { grep -vE '^\s*include' /etc/logrotate.conf; echo 'include /etc/logrotate.d/rsyslog'; } | sudo tee $g >/dev/null
  sudo nice -n 19 ionice -c3 logrotate -f $g; sudo rm -f $g   # compresses last week's file
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

`report` emits a markdown table — disk free, RAM, load, how many nodes are healthy, and their log level:

| machine | os | kernel | uptime | disk free | ram | cpu load | nodes ok | log level |
|---|---|---|---|---|---|---|---|---|
| do-sh0 | Ubuntu 22.04.5 LTS | 5.15.0-191 | 1 minute | 50G free / 97G (49% used) | 1.0Gi / 7.8Gi | 0.84 0.36 0.13 | 1/1 | *:INFO |

Watch the trend, not the snapshot: disk is the one that ends squads. See §5 — the
deep-history box grows at ~17.6 GB per epoch and a full disk stops the nodes. DigitalOcean's
per-droplet graphs cover CPU/RAM/IO history; this table is the cross-machine view it lacks.

### 8.5 Adding or reinstalling a machine — checklist

Every row is a mistake that was made, or nearly made, on this fleet.

| # | Do | Why |
|---|---|---|
| 1 | Decide the role first: observing squad, deep-history squad, multikey **main**, or multikey **backup** | every row below depends on it |
| 2 | Upgrade with **option 5 `upgrade_multikey`** on multikey hosts, **option 6 `upgrade_squad`** on squads, never option 4 | plain `upgrade` leaves `DbLookupExtensions` off |
| 3 | After `install` / `add_node` / `observers` / `multikey`, run `./scripts/mvx-fleet-maint.sh loglevel` | their unit template starts nodes at `*:DEBUG` (§8.3) |
| 4 | Deep-history box: `~/mvx-deephistory-apply.sh` **before the first start** and after every upgrade | stock config prunes the window to 4 epochs at the next boundary (§4). In historical-balances mode it also pins `PeerStatePruningEnabled = false`; with pruning on, the metachain deadlocked on 2026-09-09 |
| 5 | Multikey: confirm the key count in `allValidatorsKeys.pem` and `RedundancyLevel` (0 main, 1 backup), not the node's own key | the node's own key is a throwaway in multikey mode (§8.3) |
| 6 | Multikey: a main and its backup are **never down together**, for any reboot, restart or upgrade | the backup signs only while the main is silent |
| 7 | Intel NUCs: install `scripts/mvx-thermal-cap.sh` (12 W package cap + 88 °C watch) | degraded cooling hard-resets the box with no log at all (§7) |
| 8 | Add the machine to `~/.mvx-fleet.hosts` (never the repo), then `survey`: every node `gap≈0`, `syncing=0`, `log=*:INFO` | the inventory is what `maintain`, `report` and `loglevel` walk |
| 9 | Deep-history box: guard and prune timers, and `PROBE_MIN_EPOCH` from `mvx-history-guard.sh floor` | §9. Size the prune window one epoch larger than you query (§9.3a) |

---

## 9. Guarding against silent history loss

**Sync status describes the tip. It says nothing about the past.** This is the failure mode
that costs you a month of reporting, and no ordinary health check sees it.

On 2026-09-07 a rebuilt squad reported `epoch 2230, gap=0, syncing=0` on all four shards —
green by every check you would think to write — while its historical smart-contract state
was gone. It was discovered a day later, by a month-end job failing.

### 9.1 How history goes missing without anything looking wrong

From `epochStart/bootstrap/process.go`:

```go
shouldStartFromNetwork := e.generalConfig.GeneralSettings.StartInEpochEnabled || e.flagsConfig.ForceStartFromNetwork
if !shouldStartFromNetwork {
    return e.bootstrapFromLocalStorage()      // replay forward — history preserved
}
```

and inside `startFromSavedEpoch()`, the fork is `computeIfCurrentEpochIsSaved()`:

- Node restarts **while the network is still in the epoch it last stored** → resumes from
  storage, replays the missed blocks, **no hole**.
- An **epoch boundary passed while it was down** → epoch-start bootstrap: it downloads the
  current accounts trie and *skips* the blocks between. Those blocks, and the contract
  storage tries for that span, are never written. Permanently.

The state trie is a *snapshot* (downloadable at a point in time). Block and transaction
history is a *log* — only ever accumulated by processing. That asymmetry is the whole story:
after a fast bootstrap the node looks perfect and answers about the tip correctly, while
`getNodeFromDB: key not found` waits in the past.

**So the reaction window is "before the next epoch boundary"** — mainnet epochs start
~17:40 UTC daily. An outage beginning at 17:00 gives you forty minutes, not a day.

> **Supernova makes this sharper.** From `config.toml`, activation at epoch 2233 sets
> `RoundDuration = 600` and `RoundsPerEpoch = 144000` — epoch length stays 24 h, but there
> are **10× the blocks**. A replay after a long outage costs ten times as much.

### 9.1a Historical **reads** and historical **execution** are different capabilities

A flagless squad (this one) answers historical *reads* and cannot do historical *execution*.
That distinction is invisible until a job needs the second one.

| query | needs | works here |
|---|---|---|
| `/address/<sc>?blockNonce=` | account in the epoch's trie | ✅ back to the window start |
| `/address/<sc>/keys?blockNonce=` | contract storage trie | ✅ (65,575 keys at epoch 2200) |
| `/vm-values/query?blockNonce=` | **executes the contract** | ❌ at any past epoch |

Execution needs the intermediate trie nodes that only `-operation-mode historical-balances`
retains — the mode §2 rejects for unbounded growth. `Preferences.FullArchive = true` does
**not** substitute for it: tested on shard-1 and metachain, same
`getNodeFromDB: key not found`, reverted.

> **Do not diagnose a regression from one successful query.** In September 2026 a query at
> epoch 2224 was taken as proof the squad could answer historically. It could not: the query
> ran at 14:02 and epoch 2225 began at 17:43, so 2224 *was the current epoch*. The tell that
> it was never a regression is that failure is **uniform** — epochs a month before the
> incident fail identically. Damage is not uniform; a missing capability is.

Practical split for a flagless squad: **reads from the squad, execution from a deep-history
gateway.** Size a probe accordingly — `PROBE_FUNC=""` in `~/.mvx-guard.conf` tests a read,
otherwise `verify` alerts every morning about a capability the node was never configured to
have.

> **Update 2026-09-11 — with `historical-balances` on, execution reaches back too.** This
> box switched to the mode on 2026-09-08 (§9.3a). The expectation was that execution would
> work only for epochs recorded *after* the switch. Measured three days later, it also works
> for epochs recorded **before** it. The staking job's read and `getAmountOut` returned
> correct answers for epochs 2194–2227. Prices for 2224–2227 are bit-identical to the
> official gateway's. The trie data had been on disk all along; the flagless configuration
> just never looked it up. Which of the mode's settings unlocks it is not isolated, but it
> is not `FullArchive` alone (tested above). What does not come back is a *block gap*:
> 2228–2230, the outage, fail either way.

### 9.2 `scripts/mvx-history-guard.sh`

```bash
./mvx-history-guard.sh watch     # every 5 min: alive, synced, not restart-looping
./mvx-history-guard.sh verify    # daily: can it still ANSWER a historical query?
./mvx-history-guard.sh capture   # daily: this epoch's snapshot onto disk
```

`verify` is the one nothing else covers. It resolves the epoch-start nonce N epochs back and
runs a real **contract execution** (`/vm-values/query`) against it — not just an account
read. A balance lookup touches few trie nodes and passes even when contract storage is gone;
only executing a contract exercises the SC storage trie. Set `PROBE_MIN_EPOCH` to the first
epoch the node accumulated cleanly, so it tests what *should* be intact instead of alerting
forever about damage that cannot be repaired.

`capture` removes node health from the critical path for reporting: the month's data lands
on disk as each epoch starts, so an incident costs operations time rather than data.

Calibration lessons from the first week, all built into the script:

- **A slow answer is not a missing one.** After Supernova, listing the pool's ~65k keys at
  a past block took 51 s. The 15 s cap turned that into a daily "history damaged" alarm
  while history was intact. Historical calls now get `SLOW_TIMEOUT` (180 s), and the read
  check targets `CAPTURE_SC`, the ~4k-key contract the monthly job actually reads (~1 s).
- **An empty answer is a failure.** A price query whose dependency epoch is missing
  returns `returnData: null` with no error, and the job would record price 0. `verify`,
  `capture` and `floor` treat empty `returnData` as failed.
- **Alert on gaps, not on the syncing flag.** At 600 ms rounds `erd_is_syncing` flickers on
  healthy nodes, and a one-minute home internet drop raises it on every node at once. A
  gap above `GAP_LIMIT` alerts immediately. The flag alone must persist across two runs
  (10 min), which still catches a node stuck restarting.
- **An edge-triggered alert hides a long failure.** `verify` messages only on a change,
  so a check red since yesterday was silent today. The daily `report` now carries the
  current history-check state.

Config in `~/.mvx-guard.conf` (mode `600` — it holds a bot token). Alerts are
edge-triggered: one message when something breaks, one when it recovers. Install as timers:

```bash
sudo systemctl enable --now mvx-guard-watch.timer    # */5 min
sudo systemctl enable --now mvx-guard-verify.timer   # daily 06:00 UTC
sudo systemctl enable --now mvx-guard-capture.timer  # daily 19:00 UTC (after epoch start)
```

### 9.3 `StartInEpochEnabled = false` — an option, deliberately not the default

§2 rejects `-operation-mode historical-balances`, correctly: it forces five settings at once,
including both cleanup flags off, which makes `NumEpochsToKeep` dead and growth unbounded.

But **`StartInEpochEnabled` is a plain `config.toml` setting and can be set on its own**,
keeping retention intact. Setting it `false` means the node can never fast-bootstrap past a
gap — it replays instead, so an outage costs time rather than history.

It is not the default here, because it removes your escape hatch: a node that cannot
bootstrap from storage falls back to genesis (~239 days, measured — see §2). It converts
"permanent hole" into "possibly very long recovery", and post-Supernova a multi-day outage
means replaying >1M blocks per shard.

Adopt it only **after** §9.2 alerting exists, so outages are caught in minutes and the replay
is minutes of blocks. If you do, put it in `mvx-deephistory-apply.sh` so upgrades cannot
silently revert it, and keep the two-phase pattern of `scripts/phase2-when-ready.sh` for any
rebuild: sync normally to the tip first, switch only once caught up.

### 9.3a Making `historical-balances` affordable — prune the window from outside

The objection to `historical-balances` in §2 is storage, not correctness: it forces both
`CleanOldEpochsData` flags false, so `NumEpochsToKeep` is inert and nothing is ever deleted.
`scripts/mvx-epoch-prune.sh` puts the ceiling back from outside the node:

```bash
./mvx-epoch-prune.sh --keep 62 --dry-run    # show exactly what would go
./mvx-epoch-prune.sh --keep 62              # keep the newest 62 epochs
```

**Why deleting epoch directories is safe here.** `[StateTriesConfig] SnapshotsEnabled = true`
means the node writes a *full* trie snapshot at every epoch boundary, so each `Epoch_*`
directory is self-contained rather than a delta against older ones. That is visible on disk:
epochs are a consistent ~11 GB on shard 1, not variable. It is also precisely what the
node's own `AccountsTrieCleanOldEpochsData` does when it is permitted to. **Check
`SnapshotsEnabled` before trusting this** — with snapshots off, epochs are not
self-contained and external deletion would corrupt newer state.

Verified 2026-09-08: removed 6 epochs while all four nodes were running; all stayed
`active`, `gap=0`, zero panics or storage errors.

Guards, because this deletes data:

| guard | why |
|---|---|
| refuses if the current epoch cannot be read | a failed API call must not compute a floor |
| refuses `--keep` below `MIN_KEEP` (5) | a typo must not wipe the archive |
| refuses more than `MAX_DELETE` (10) epochs *with data* without `--force` | a bad epoch reading cannot cascade |
| only matches `Epoch_<number>` | `Static/` holds the cross-epoch indexes — never touch it |
| `--dry-run` | prints the exact directories and total size; never sends an alert |

**Empty skeleton directories.** In this mode the node also leaves `Epoch_*` directories
for epochs it never stored: empty LevelDB databases (no tables), a few KiB each, appearing
about one per hour. The prune sweeps them without counting them toward `MAX_DELETE`. It
used to count them. From 2026-09-09 every nightly run saw 13, then 34 "epochs" to delete,
refused, and pruned nothing, while the real data was all inside the window. A guard that
trips on junk teaches you to ignore it, so the check now looks for LevelDB tables (or a
non-empty journal) before calling a directory an epoch.

Install as a daily timer (00:00 UTC is mid-epoch, so it never races an epoch transition):

```bash
sudo systemctl enable --now mvx-epoch-prune.timer
```

This combination — `historical-balances` for execution, external prune for the ceiling — is
not a configuration MultiversX documents. Re-check `mvx-history-guard.sh floor` after the
first few prunes to confirm the window is what you expect.

**Size the window one epoch larger than you query.** The staking job resolves each epoch's
*metachain* start nonce and passes it as `blockNonce` to a query that runs on *shard 1*
(the pool contract). Shard 1's nonces run ~8,000 ahead of the metachain's, so that number
names a shard-1 block from *before* the epoch boundary: ~13 h earlier with 6 s rounds,
~80 min after Supernova. The official gateway resolves it the same way, which is why the
numbers always matched. The consequence for storage is that **the price for epoch N reads
epoch N−1's directory**. Proven on 2026-09-11: with `Epoch_2230` moved away, 2231's staking
read still worked but its price came back empty. Restoring 2230 fixed it. So a window of
K epochs serves the full job for K−1 of them. For "a calendar month, run in the first three
days of the next", keep 34, not 33.

**Trimming older epochs by hand: move aside, verify, then delete.** Deleting history is
irreversible, and on this mode a node that cannot start from its own disk replays from
genesis (§2). So never `rm` epochs in one step:

```bash
Q=~/epoch-quarantine-$(date +%Y%m%d)            # same filesystem: mv is an instant rename
# 1. record the answers you care about (staking keys + price) for the epochs you KEEP
# 2. move Epoch_<n> below the cut out of every node-*/db/1/ into $Q/node-N/
# 3. re-run 1 — the answers must be byte-identical; restore anything they depend on
# 4. restart ONE node — its log must say "Bootstrap epoch = <current>", not genesis
# 5. wait for the next epoch change, check again, only then: rm -rf "$Q"
```

Done this way on 2026-09-11, it caught the N−1 dependency above at step 3, with nothing
lost. The kept run is 2230 (a dependency only) + 2231 onward, because 2228–2230 are the
outage gap and a run broken by a gap is no use to a monthly job.

**After Supernova, 83 % of the growth is metachain validator statistics.** Measured over
the first Supernova night, a historical-balances epoch comes to ~147 GB. About 122 GB of
that is the metachain's `PeerAccountsTrie`, rewritten every block and never pruned here:
`PeerStatePruningEnabled` must stay `false`, since with it on the metachain deadlocked
after a restart (2026-09-09). At that rate a 4 TB disk holds ~23 epochs. Neither the
staking read nor the price query touches that store; they read `AccountsTrie`. So
`mvx-epoch-prune.sh` has a second step that keeps validator statistics only for the
newest `PEER_KEEP` epochs. The default of 4 (the current epoch plus three behind it) is what a
stock node keeps with `NumEpochsToKeep = 4`; below the node's `NumActivePersisters` (3) it is
refused. That brings an
epoch to ~25 GB, and the same disk to ~120 epochs.

| setting (in `~/.mvx-guard.conf`) | meaning |
|---|---|
| `PEER_TRIM=off` | default — step 2 does nothing |
| `PEER_TRIM=report` | log what would be removed; delete nothing |
| `PEER_TRIM=on` | remove `Epoch_N/Shard_metachain/PeerAccountsTrie` for N < current − PEER_KEEP + 1 |

Refused below `NumActivePersisters`, capped at `PEER_MAX_DELETE` (5) epochs per run, skipped
whenever step 1 refuses, and it never touches any other store. Switch to `on` only after
the staged test passes:

```bash
./mvx-peer-trim-test.sh baseline      # staking keys + price, FIRST_EPOCH..current
./mvx-peer-trim-test.sh move 2231     # refused if the node still has that epoch open
./mvx-peer-trim-test.sh compare       # must print "all answers identical"
./mvx-peer-trim-test.sh restart       # metachain node must boot from disk and resync
./mvx-peer-trim-test.sh compare
# ...after the next epoch change:
./mvx-peer-trim-test.sh compare && ./mvx-peer-trim-test.sh finish   # then PEER_TRIM=on
# any mismatch: ./mvx-peer-trim-test.sh restore
```

At every restart in this mode each node logs `WARN could not retrieve snapshot info — key
not found`. It appeared at every restart since 2026-09-09, before any epoch was moved, and
does not trigger a state re-sync. It is routine, not a symptom.

### 9.4 Order of defence

1. **UPS with automatic graceful shutdown** — removes the trigger. The 2026-09 incident began
   with two unclean reboots two minutes apart.
2. **Detection in minutes** (§9.2) — the multiplier. Caught in 5 minutes, a replay is
   5 minutes of blocks; caught in 2 days, it is a permanent hole.
3. **Capture derived data continuously** (§9.2) — makes reporting independent of node health.
4. **`StartInEpochEnabled = false`** (§9.3) — only once 2 is in place.

---

## 10. Reference

- Deep-history docs: https://docs.multiversx.com/integrators/deep-history-squad/
- Operation modes: https://docs.multiversx.com/validators/node-operation-modes/
- Authoritative flag behaviour: `~/go/src/github.com/multiversx/mx-chain-go/common/operationmodes/historicalBalances.go`
- Mainnet genesis: `1596117600` = **2020-07-30 14:00 UTC**; epoch N starts genesis + N days.
  Daily-archive naming uses that date (`31-Jul-2026` = epoch 2192).

Initial deep-history floors from the 1 Aug 2026 build (historical; since 2026-09-11 the
kept run starts at epoch 2231, with 2230 retained only as its dependency — §9.3a):

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
