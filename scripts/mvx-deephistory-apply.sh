#!/bin/bash
# =============================================================================
#  MultiversX Deep-History Squad — re-apply all local customizations
# =============================================================================
#  RUN THIS AFTER EVERY:
#    ./script.sh upgrade | upgrade_squad   -> overwrites each node's config/ wholesale
#    ./script.sh github_pull               -> `git reset --hard` wipes scripts repo edits
#    ./script.sh observing_squad           -> regenerates systemd units
#
#  Scope: config.toml settings ONLY. The upgrade scripts already preserve prefs.toml
#  (save/restore around update()), the six variables.cfg fields, and the systemd units.
#  What they do NOT preserve are the config.toml keys below -- notably NumEpochsToKeep,
#  which reverts to 4 and will prune the retention window away.
#
#  ORDER MATTERS — run this BEFORE starting the nodes:
#      ./script.sh upgrade_squad     # leaves nodes stopped, config/ reset to stock
#      ./mvx-deephistory-apply.sh    # <-- here
#      ./script.sh start
#
#  Stock config.toml ships AccountsTrieCleanOldEpochsData=true with NumEpochsToKeep=4.
#  A node started on stock config will, at the next epoch boundary, prune the accounts
#  trie down to 4 epochs — destroying the retention window. That is not recoverable
#  without a full re-sync.
#
#  Usage:  ./mvx-deephistory-apply.sh [--restart]
#  Env:    NUM_EPOCHS_TO_KEEP (default 62)   TRIE_DEADLINE_MS (default 100000)
#          NODE_DISPLAY_NAME (explorer name; lost on every upgrade)
#  Settings are remembered in ~/.mvx-deephistory.conf after the first run, so a
#  post-upgrade invocation needs no arguments.
# =============================================================================
set -uo pipefail

NODES="${NODES:-0 1 2 3}"

# Persisted per-host settings. Retention depends on the disk (see README §5) and the
# explorer display name is wiped by every upgrade, so both are remembered here rather
# than retyped. Precedence: environment variable > this file > built-in default.
CONF="${MVX_DH_CONF:-$HOME/.mvx-deephistory.conf}"
if [ -f "$CONF" ]; then
  _e_keep="${NUM_EPOCHS_TO_KEEP:-}"; _e_trie="${TRIE_DEADLINE_MS:-}"; _e_name="${NODE_DISPLAY_NAME:-}"
  _e_hist="${HISTORICAL_BALANCES:-}"
  # shellcheck disable=SC1090
  . "$CONF"
  [ -n "$_e_keep" ] && NUM_EPOCHS_TO_KEEP="$_e_keep"
  [ -n "$_e_trie" ] && TRIE_DEADLINE_MS="$_e_trie"
  [ -n "$_e_name" ] && NODE_DISPLAY_NAME="$_e_name"
  [ -n "$_e_hist" ] && HISTORICAL_BALANCES="$_e_hist"
fi

NUM_EPOCHS_TO_KEEP="${NUM_EPOCHS_TO_KEEP:-62}"
TRIE_DEADLINE_MS="${TRIE_DEADLINE_MS:-100000}"
NODE_DISPLAY_NAME="${NODE_DISPLAY_NAME:-}"
# HISTORICAL_BALANCES=1 switches this squad from "retention" mode to "full archive"
# mode. They are mutually exclusive by design — see README §2 and §9.1a:
#
#   0 (default)  bounded storage (NumEpochsToKeep epochs), historical READS only.
#   1            -operation-mode historical-balances: historical READS *and*
#                EXECUTION (/vm-values/query at past blocks), at the cost of
#                unbounded growth — the mode hard-forces both CleanOldEpochsData
#                flags false, so NumEpochsToKeep becomes inert and nothing is ever
#                deleted. Plan a periodic re-bootstrap before the disk fills.
#
# Whichever is set, this script must agree with it, or the next upgrade silently
# reverts the node to the other mode.
HISTORICAL_BALANCES="${HISTORICAL_BALANCES:-0}"
NODES_ROOT="${NODES_ROOT:-$HOME/elrond-nodes}"
SCRIPTS_CFG="${SCRIPTS_CFG:-$HOME/mx-chain-scripts/config/variables.cfg}"
RESTART=0
[ "${1:-}" = "--restart" ] && RESTART=1

RED=$'\e[0;31m'; GRN=$'\e[0;32m'; YEL=$'\e[0;33m'; NC=$'\e[0m'
FAIL=0
ok()   { echo "   ${GRN}ok${NC}   $*"; }
warn() { echo "   ${YEL}warn${NC} $*"; }
bad()  { echo "   ${RED}FAIL${NC} $*"; FAIL=1; }

# set_kv <file> <key> <value> — replaces a top-level "Key = value" line, preserving indent.
# Fails loudly if the key vanished (upstream renamed it) instead of silently doing nothing.
set_kv() {
  local f="$1" k="$2" v="$3"
  if ! grep -qE "^[[:space:]]*${k}[[:space:]]*=" "$f"; then
    bad "$(basename "$f"): key '${k}' NOT FOUND — upstream config format may have changed"
    return 1
  fi
  sed -i -E "s|^([[:space:]]*)${k}[[:space:]]*=.*|\1${k} = ${v}|" "$f"
  local now; now=$(grep -E "^[[:space:]]*${k}[[:space:]]*=" "$f" | head -1 | sed 's/^[[:space:]]*//')
  ok "${now}"
}

echo "=============================================================="
echo " Deep-history squad: re-applying customizations"
echo " retention: ${NUM_EPOCHS_TO_KEEP} epochs   trie deadline: ${TRIE_DEADLINE_MS} ms"
echo " display name: ${NODE_DISPLAY_NAME:-<unset>}   config: ${CONF}"
echo "=============================================================="

# Warn if nodes are already up: edits to config.toml are read only at startup, so a
# running node keeps whatever it loaded — including stock NumEpochsToKeep=4 if this
# script was not run before the last start.
RUNNING=""
for n in $NODES; do
  [ "$(systemctl is-active "elrond-node-$n" 2>/dev/null)" = "active" ] && RUNNING="$RUNNING $n"
done
if [ -n "$RUNNING" ] && [ "$RESTART" -eq 0 ]; then
  echo
  echo "${YEL}WARNING${NC}: node(s)${RUNNING} are RUNNING."
  echo "         config.toml is only read at startup, so these changes do NOT apply yet."
  echo "         If they were started on stock config, they are running with"
  echo "         NumEpochsToKeep=4 and will prune to 4 epochs at the next epoch boundary."
  echo "         Re-run with --restart, or restart them yourself, as soon as possible."
fi

for n in $NODES; do
  CFG="$NODES_ROOT/node-$n/config/config.toml"
  echo
  echo "-- node-$n : config.toml"
  if [ ! -f "$CFG" ]; then bad "missing $CFG"; continue; fi
  cp -f "$CFG" "$CFG.bak-$(date +%Y%m%d-%H%M%S)"

  # --- API: allow long-running historical trie queries -----------------------
  set_kv "$CFG" "TrieOperationsDeadlineMilliseconds" "$TRIE_DEADLINE_MS"

  # --- Deep history, bounded to NUM_EPOCHS_TO_KEEP epochs --------------------
  # Deep history comes from AccountsStatePruningEnabled=false (keeps intra-epoch
  # state). The two CleanOldEpochsData flags + NumEpochsToKeep bound how far back
  # it is retained. This is exactly how the public gateway does 3-epoch deep
  # history with NumEpochsToKeep=4.
  # NOTE: this only works WITHOUT -operation-mode historical-balances, which
  # hard-forces both cleanup flags to false (see operationmodes/historicalBalances.go).
  set_kv "$CFG" "AccountsStatePruningEnabled"        "false"
  if [ "$HISTORICAL_BALANCES" = "1" ]; then
    # historical-balances hard-forces both of these false at runtime regardless of
    # what the file says. Writing them false keeps config.toml honest about what the
    # node is actually doing, instead of claiming a retention window it does not have.
    set_kv "$CFG" "ObserverCleanOldEpochsData"       "false"
    set_kv "$CFG" "AccountsTrieCleanOldEpochsData"   "false"
    # NumEpochsToKeep is inert in this mode; left at its value purely as a marker of
    # the window you intend to return to after a re-bootstrap.
    set_kv "$CFG" "NumEpochsToKeep"                  "$NUM_EPOCHS_TO_KEEP"
  else
    set_kv "$CFG" "ObserverCleanOldEpochsData"       "true"
    set_kv "$CFG" "AccountsTrieCleanOldEpochsData"   "true"
    set_kv "$CFG" "NumEpochsToKeep"                  "$NUM_EPOCHS_TO_KEEP"
  fi
  # Empty pattern => no epoch is exempt from trie removal. Stock "%50" would keep
  # every 50th epoch forever, which defeats a fixed storage ceiling.
  set_kv "$CFG" "AccountsTrieSkipRemovalCustomPattern" '""'

  # --- Full-history tx/block lookup ----------------------------------------
  # Scoped to the [DbLookupExtensions] section only: 'Enabled' is far too common
  # a key name to rewrite globally.
  if grep -q "^\[DbLookupExtensions\]" "$CFG"; then
    awk '
      /^\[DbLookupExtensions\]/ { inSec = 1 }
      /^\[/ && !/^\[DbLookupExtensions\]/ { inSec = 0 }
      { if (inSec && $0 ~ /^[[:space:]]*Enabled[[:space:]]*=/) sub(/Enabled[[:space:]]*=.*/, "Enabled = true"); print }
    ' "$CFG" > "$CFG.tmp" && mv "$CFG.tmp" "$CFG"
    ok "DbLookupExtensions.Enabled = true"
  else
    bad "[DbLookupExtensions] section not found"
  fi

  # --- prefs.toml: explorer display name ------------------------------------
  # NOTE: upgrades already preserve this on their own -- both `upgrade` and
  # `upgrade_squad` copy prefs.toml to prefs.toml.save before update() and mv it back
  # after. This block is a convenience for setting the name non-interactively on a
  # fresh install, or changing it across all nodes at once. Left unset, prefs.toml
  # is not touched.
  PREFS="$NODES_ROOT/node-$n/config/prefs.toml"
  if [ -n "$NODE_DISPLAY_NAME" ]; then
    if [ -f "$PREFS" ]; then
      cp -f "$PREFS" "$PREFS.bak-$(date +%Y%m%d-%H%M%S)"
      set_kv "$PREFS" "NodeDisplayName" "\"$NODE_DISPLAY_NAME\""
    else
      bad "missing $PREFS"
    fi
  else
    warn "NODE_DISPLAY_NAME unset — leaving prefs.toml alone."
    warn "     Set it once and it is remembered: NODE_DISPLAY_NAME=foxsy $0"
  fi
done

# Remember the settings for next time (after an upgrade wipes the node configs).
cat > "$CONF" <<EOF
# Written by mvx-deephistory-apply.sh — per-host settings, survives node upgrades.
NUM_EPOCHS_TO_KEEP="$NUM_EPOCHS_TO_KEEP"
TRIE_DEADLINE_MS="$TRIE_DEADLINE_MS"
NODE_DISPLAY_NAME="$NODE_DISPLAY_NAME"
# 0 = bounded retention, historical reads only.
# 1 = -operation-mode historical-balances: reads AND execution at past blocks,
#     unbounded storage. See README §9.3.
HISTORICAL_BALANCES="$HISTORICAL_BALANCES"
EOF

# --- systemd units -----------------------------------------------------------
# The install writes these with *:DEBUG and appends $NODE_EXTRA_FLAGS. We force
# INFO (DEBUG dumps full SC payloads and floods the journal), and we make the
# -operation-mode flag match HISTORICAL_BALANCES in BOTH directions, so that a
# unit regenerated by an upgrade cannot silently flip the squad's mode.
echo
echo "-- systemd units"
UNIT_CHANGED=0
for n in $NODES; do
  U="/etc/systemd/system/elrond-node-$n.service"
  [ -f "$U" ] || { warn "$U missing"; continue; }
  BEFORE=$(md5sum "$U" | cut -d' ' -f1)
  # Always normalise the log level. DEBUG dumps full SC payloads (382 KB per 40 lines).
  sudo sed -i -E 's/-log-level \*:DEBUG/-log-level *:INFO/g' "$U"
  # Then make the operation-mode flag match the configured squad mode. Doing this in
  # both directions is the point: whichever mode you chose, an upgrade that regenerates
  # the units cannot silently move you to the other one.
  if [ "$HISTORICAL_BALANCES" = "1" ]; then
    grep -qE "^[[:space:]]*ExecStart=.*--operation-mode[[:space:]=]+historical-balances" "$U" \
      || sudo sed -i -E 's|(^[[:space:]]*ExecStart=.*/node)|\1 --operation-mode historical-balances|' "$U"
  else
    sudo sed -i -E 's/[[:space:]]*--?operation-mode[[:space:]=]+historical-balances//g' "$U"
  fi
  AFTER=$(md5sum "$U" | cut -d' ' -f1)
  [ "$BEFORE" != "$AFTER" ] && UNIT_CHANGED=1
  LINE=$(grep -E "^[[:space:]]*ExecStart=" "$U" | grep -v '#' | sed 's/^[[:space:]]*//')
  HAS_HB=0; case "$LINE" in *"historical-balances"*) HAS_HB=1 ;; esac
  case "$LINE" in *"*:DEBUG"*) bad "node-$n still at DEBUG"; continue ;; esac
  if [ "$HISTORICAL_BALANCES" = "1" ] && [ "$HAS_HB" = "0" ]; then
    bad "node-$n: historical-balances requested but flag absent"
  elif [ "$HISTORICAL_BALANCES" = "0" ] && [ "$HAS_HB" = "1" ]; then
    bad "node-$n: historical-balances present but NOT requested (would disable pruning)"
  else
    ok "node-$n: $(echo "$LINE" | grep -o '\-log-level [^ ]*')$([ "$HAS_HB" = 1 ] && echo ' + historical-balances')"
  fi
done
[ "$UNIT_CHANGED" -eq 1 ] && { sudo systemctl daemon-reload; ok "daemon-reload done"; }

# --- variables.cfg -----------------------------------------------------------
# NODE_EXTRA_FLAGS *is* one of the six fields github_pull preserves, so it decides
# what a future `observing_squad` reinstall bakes into freshly generated units. Keep
# it in step with HISTORICAL_BALANCES in both directions.
echo
echo "-- variables.cfg"
if [ -f "$SCRIPTS_CFG" ]; then
  WANT=""
  [ "$HISTORICAL_BALANCES" = "1" ] && WANT="--operation-mode historical-balances"
  CUR=$(grep -E '^NODE_EXTRA_FLAGS=' "$SCRIPTS_CFG" | head -1 | sed -E 's|^NODE_EXTRA_FLAGS="?([^"]*)"?.*|\1|')
  if [ "$CUR" != "$WANT" ]; then
    sed -i -E "s|^NODE_EXTRA_FLAGS=.*|NODE_EXTRA_FLAGS=\"$WANT\"|" "$SCRIPTS_CFG"
    ok "NODE_EXTRA_FLAGS set to \"$WANT\" (was \"$CUR\")"
  else
    ok "NODE_EXTRA_FLAGS=\"$CUR\""
  fi
else
  warn "$SCRIPTS_CFG not found"
fi

# --- optional restart --------------------------------------------------------
if [ "$RESTART" -eq 1 ]; then
  echo
  echo "-- restarting nodes (sequential, so shards do not all drop at once)"
  for n in $NODES; do
    sudo systemctl restart "elrond-node-$n"
    ok "node-$n restarted ($(systemctl is-active "elrond-node-$n"))"
    sleep 10
  done
fi

echo
if [ "$FAIL" -eq 0 ]; then
  echo "${GRN}All customizations applied cleanly.${NC}"
else
  echo "${RED}One or more settings could not be applied — read the FAIL lines above.${NC}"
  echo "A missing key usually means upstream renamed it; check config.toml by hand."
fi
exit "$FAIL"
