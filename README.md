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

| Action | What it destroys |
|---|---|
| `script.sh upgrade` / `upgrade_squad` | `cp -r <config-repo>/* $WORKDIR/config` — overwrites **all** of `config/`, including `config.toml` **and `prefs.toml`** |
| `script.sh github_pull` (option 14) | `git reset --hard HEAD` — discards every local edit to `mx-chain-scripts`, **except** the six `variables.cfg` fields below, which are saved and restored around the reset |
| `script.sh observing_squad` | regenerates systemd units from `functions.cfg` |

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

It is idempotent and fails loudly if upstream renames a key.

---

## 5. Storage

Measured on this host, shard 0: **~3.7 GB per epoch**. Empty epoch dirs are ~372 KB —
the pruning storer pre-creates all 62 directories on start, which is normal and harmless.

Rough steady state at `NumEpochsToKeep = 62`: **~700 GB** across all four nodes.
Against 3.6 TB that is comfortable, but it is a *rolling* figure — verify it plateaus
rather than assuming it will.

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

## 8. Reference

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

- **Rotate the GitHub PAT** in `mx-chain-scripts/config/variables.cfg` — stored in plaintext.
- Helper scripts on the host: `~/mvx-deephistory-apply.sh`, `~/phase2-when-ready.sh`.
- Backups: `/root/elrond-unit-backups-*`, per-node `config/config.toml.bak-*`.
