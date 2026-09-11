#!/usr/bin/env bash
#
# mvx-epoch-prune.sh — keep a fixed epoch window on disk, from outside the node.
#
# Why this exists
# ---------------
# `-operation-mode historical-balances` is the only way to get historical CONTRACT
# EXECUTION (/vm-values/query at a past block). But it hard-forces both
# CleanOldEpochsData flags to false, so NumEpochsToKeep becomes inert and the node
# never deletes anything — storage grows until the disk fills and the nodes stop.
#
# This script restores the ceiling externally: keep the newest N epochs, delete the
# rest. That is safe here because `[StateTriesConfig] SnapshotsEnabled = true` — the
# node writes a FULL trie snapshot at every epoch boundary, so each Epoch_* directory
# is self-contained rather than a delta against older ones. (It is also exactly what
# the node's own AccountsTrieCleanOldEpochsData does when it is allowed to.)
#
# Verify that assumption on your setup before trusting this:
#     grep -A3 '\[StateTriesConfig\]' config/config.toml   # SnapshotsEnabled = true
#     ./mvx-history-guard.sh floor                          # floor should equal the window
#
# Safety
# ------
#   * refuses to run if the current epoch cannot be read from the node
#   * refuses a window smaller than MIN_KEEP (a typo must not wipe the archive)
#   * refuses to delete more than MAX_DELETE epochs in one run without --force,
#     so a bad epoch reading cannot cascade into deleting everything
#   * never touches Static/ or anything that is not Epoch_<number>
#   * --dry-run prints exactly what it would remove, and never alerts
#
# Empty skeletons
# ---------------
# In historical-balances mode the node leaves behind Epoch_* directories for epochs it
# never stored: empty LevelDB databases (LOCK, LOG, MANIFEST, no tables), a few KiB each,
# appearing roughly one epoch per hour below the window. They hold no data, so they are
# swept without counting toward MAX_DELETE. Counted, they made every nightly run exceed
# the limit and refuse, so nothing was pruned from 2026-09-09 until this was fixed.
#
# Validator-statistics trim (metachain only)
# ------------------------------------------
# Historical-balances mode keeps every version of the metachain's validator-statistics
# trie (PeerAccountsTrie); PeerStatePruningEnabled must stay false — with it on, the
# metachain deadlocked after a restart on 2026-09-09. It is rewritten every block, so
# after Supernova it is ~122 GB of a ~147 GB epoch. The staking and price queries never
# read it (they use AccountsTrie), and the node only opens its last NumActivePersisters
# epochs. So the second step removes Epoch_N/Shard_metachain/PeerAccountsTrie for all but
# the newest PEER_KEEP epochs, which takes an epoch from ~147 GB to ~25 GB.
#
#   PEER_TRIM=off      do nothing (default)
#   PEER_TRIM=report   log what would be removed, delete nothing
#   PEER_TRIM=on       remove it
#
# PEER_KEEP is refused below the node's NumActivePersisters (3). At most PEER_MAX_DELETE
# epochs are trimmed per run without --force. Only a directory named exactly
# PeerAccountsTrie under Shard_metachain is ever touched. Validate with a staged test
# before `on` (README §9.3a, scripts/mvx-peer-trim-test.sh).
#
# Usage: mvx-epoch-prune.sh [--keep N] [--peer-trim off|report|on] [--dry-run] [--force]

set -uo pipefail

CONF="${MVX_GUARD_CONF:-$HOME/.mvx-guard.conf}"
[ -f "$CONF" ] && . "$CONF"

KEEP="${KEEP:-62}"
MIN_KEEP="${MIN_KEEP:-5}"
MAX_DELETE="${MAX_DELETE:-10}"
NODES_ROOT="${NODES_ROOT:-$HOME/elrond-nodes}"
STATUS_PORT="${STATUS_PORT:-8083}"     # metachain: authoritative for epoch number
PEER_TRIM="${PEER_TRIM:-off}"          # off | report | on
PEER_KEEP="${PEER_KEEP:-3}"            # newest epochs whose validator statistics stay
PEER_MAX_DELETE="${PEER_MAX_DELETE:-5}"
DRY=0; FORCE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --keep)      KEEP="$2"; shift 2 ;;
    --peer-trim) PEER_TRIM="$2"; shift 2 ;;
    --dry-run)   DRY=1; shift ;;
    --force)     FORCE=1; shift ;;
    *) echo "usage: $0 [--keep N] [--peer-trim off|report|on] [--dry-run] [--force]" >&2; exit 2 ;;
  esac
done
case "$PEER_TRIM" in off|report|on) ;; *) echo "--peer-trim must be off, report or on" >&2; exit 2 ;; esac

log() { printf '[%s] %s\n' "$(date -u '+%Y-%m-%d %H:%M:%SZ')" "$*"; }

notify() {
  local text="$1"
  log "$text"
  if [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && [ -n "${TELEGRAM_CHAT_ID:-}" ]; then
    curl -s --max-time 15 -o /dev/null \
      "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
      --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
      --data-urlencode "text=${text}" || true
  fi
}

# --- guards -------------------------------------------------------------------

case "$KEEP" in ''|*[!0-9]*) log "ERROR: --keep must be a number"; exit 1 ;; esac
if [ "$KEEP" -lt "$MIN_KEEP" ]; then
  log "REFUSING: keep=$KEEP is below MIN_KEEP=$MIN_KEEP"; exit 1
fi

CUR=$(curl -s --max-time 10 "http://localhost:$STATUS_PORT/node/status" 2>/dev/null \
      | jq -r '.data.metrics.erd_epoch_number // empty')
case "$CUR" in
  ''|*[!0-9]*) notify "🔴 epoch-prune REFUSED: cannot read current epoch from :$STATUS_PORT — nothing deleted"; exit 1 ;;
esac
# has_data <dir> — true if any LevelDB under it holds a table or a non-empty journal.
has_data() {
  [ -n "$(find "$1" -type f \( -name '*.ldb' -o -name '*.sst' -o \
          \( -name '[0-9]*.log' -size +0 \) \) -print -quit 2>/dev/null)" ]
}

# --- step 1: epoch window -------------------------------------------------------
# returns 1 only on a refusal, which also skips step 2

prune_epochs() {
if [ "$CUR" -lt "$KEEP" ]; then
  log "current epoch $CUR < keep $KEEP — nothing to do"; return 0
fi

FLOOR=$((CUR - KEEP + 1))
log "current epoch $CUR, keeping $KEEP -> deleting Epoch_* older than $FLOOR"

PLAN=""; COUNT=0; EMPTY=""; NEMPTY=0
for nd in "$NODES_ROOT"/node-*/db/*/; do
  [ -d "$nd" ] || continue
  for d in "$nd"Epoch_*; do
    [ -d "$d" ] || continue
    e="${d##*/Epoch_}"
    case "$e" in ''|*[!0-9]*) continue ;; esac      # never touch Static or oddities
    [ "$e" -lt "$FLOOR" ] || continue
    if has_data "$d"; then
      PLAN="$PLAN$d"$'\n'; COUNT=$((COUNT + 1))
    else
      EMPTY="$EMPTY$d"$'\n'; NEMPTY=$((NEMPTY + 1))
    fi
  done
done

if [ "$COUNT" -eq 0 ] && [ "$NEMPTY" -eq 0 ]; then
  log "nothing older than $FLOOR — nothing to do"; return 0
fi

# Distinct epochs, not directories: 4 nodes means 4 dirs per epoch.
EPOCHS=$(printf '%s' "$PLAN" | sed 's|.*/Epoch_||' | sort -un | tr '\n' ' ')
NEPOCHS=$(printf '%s' "$EPOCHS" | wc -w)
SIZE=$(printf '%s' "$PLAN" | grep -v '^$' | tr '\n' '\0' | du -sch --files0-from=- 2>/dev/null | tail -1 | cut -f1)

log "would remove $COUNT directories across $NEPOCHS epochs with data (${SIZE:-0}): $EPOCHS"
log "would sweep $NEMPTY empty skeleton directories (no tables, not counted toward MAX_DELETE)"

if [ "$NEPOCHS" -gt "$MAX_DELETE" ] && [ "$FORCE" -eq 0 ]; then
  msg="🔴 epoch-prune REFUSED: $NEPOCHS epochs with data exceeds MAX_DELETE=$MAX_DELETE (current epoch $CUR, floor $FLOOR). Nothing deleted — re-run with --force if this is genuinely intended."
  if [ "$DRY" -eq 1 ]; then log "--dry-run: $msg"; else notify "$msg"; fi
  return 1
fi

if [ "$DRY" -eq 1 ]; then log "--dry-run: nothing deleted"; return 0; fi

# --- execute ------------------------------------------------------------------

BEFORE=$(df -h / | tail -1 | awk '{print $4}')
printf '%s' "$EMPTY" | while IFS= read -r d; do
  [ -n "$d" ] || continue
  rm -rf -- "$d"
done
[ "$NEMPTY" -gt 0 ] && log "swept $NEMPTY empty skeleton directories"
printf '%s' "$PLAN" | while IFS= read -r d; do
  [ -n "$d" ] || continue
  rm -rf -- "$d" && log "removed $d"
done
AFTER=$(df -h / | tail -1 | awk '{print $4}')

# Skeleton-only runs are routine housekeeping: journal only. The daily guard report is
# the heartbeat; a Telegram message every night for a few KiB would train you to ignore it.
if [ "$NEPOCHS" -gt 0 ]; then
  notify "🧹 epoch-prune: removed $NEPOCHS epochs (<$FLOOR), $SIZE freed. Disk free $BEFORE -> $AFTER. Window now $FLOOR..$CUR."
fi
return 0
}

# --- step 2: metachain validator statistics ---------------------------------------

trim_peer_state() {
  [ "$PEER_TRIM" = off ] && return 0
  local nap
  nap=$(grep -hE '^\s*NumActivePersisters\s*=' "$NODES_ROOT"/node-*/config/config.toml 2>/dev/null | head -1 | tr -dc '0-9')
  nap=${nap:-3}
  case "$PEER_KEEP" in ''|*[!0-9]*) log "peer-trim REFUSED: PEER_KEEP must be a number"; return 1 ;; esac
  if [ "$PEER_KEEP" -lt "$nap" ] || [ "$PEER_KEEP" -lt 3 ]; then
    log "peer-trim REFUSED: PEER_KEEP=$PEER_KEEP is below NumActivePersisters=$nap (epochs the node keeps open)"
    return 1
  fi

  local pfloor=$((CUR - PEER_KEEP + 1)) plan="" n=0 total=0 d e sz list=""
  for d in "$NODES_ROOT"/node-*/db/*/Epoch_*/Shard_metachain/PeerAccountsTrie; do
    [ -d "$d" ] || continue
    e="${d%/Shard_metachain/PeerAccountsTrie}"; e="${e##*/Epoch_}"
    case "$e" in ''|*[!0-9]*) continue ;; esac
    [ "$e" -lt "$pfloor" ] || continue
    has_data "$d" || continue                 # skeletons go with their epoch in step 1
    sz=$(du -sb "$d" | cut -f1)
    plan="$plan$d"$'\n'; n=$((n + 1)); total=$((total + sz))
    list="$list $e ($(awk -v b="$sz" 'BEGIN{printf "%.1f", b/1e9}') GB)"
  done
  local gb; gb=$(awk -v b="$total" 'BEGIN{printf "%.1f", b/1e9}')
  if [ "$n" -eq 0 ]; then
    log "peer-trim ($PEER_TRIM): no validator statistics older than epoch $pfloor"; return 0
  fi
  log "peer-trim ($PEER_TRIM): keeping epochs >= $pfloor; would remove:$list = $gb GB"

  if [ "$n" -gt "$PEER_MAX_DELETE" ] && [ "$FORCE" -eq 0 ]; then
    local msg="🔴 peer-trim REFUSED: $n epochs exceeds PEER_MAX_DELETE=$PEER_MAX_DELETE (current epoch $CUR). Nothing deleted."
    if [ "$DRY" -eq 1 ] || [ "$PEER_TRIM" = report ]; then log "$msg"; else notify "$msg"; fi
    return 1
  fi
  if [ "$PEER_TRIM" = report ] || [ "$DRY" -eq 1 ]; then
    log "peer-trim: report only — nothing deleted"; return 0
  fi

  local before; before=$(df -h / | tail -1 | awk '{print $4}')
  printf '%s' "$plan" | while IFS= read -r d; do
    [ -n "$d" ] || continue
    rm -rf -- "$d" && log "removed $d"
  done
  notify "🧹 peer-trim: removed metachain validator statistics for$list — $gb GB freed. Disk free $before -> $(df -h / | tail -1 | awk '{print $4}'). Kept epochs >= $pfloor."
}

prune_epochs    || exit 1
trim_peer_state || exit 1
exit 0
