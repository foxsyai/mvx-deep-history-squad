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
  # shellcheck disable=SC1090
  . "$CONF"
  [ -n "$_e_keep" ] && NUM_EPOCHS_TO_KEEP="$_e_keep"
  [ -n "$_e_trie" ] && TRIE_DEADLINE_MS="$_e_trie"
  [ -n "$_e_name" ] && NODE_DISPLAY_NAME="$_e_name"
fi

NUM_EPOCHS_TO_KEEP="${NUM_EPOCHS_TO_KEEP:-62}"
TRIE_DEADLINE_MS="${TRIE_DEADLINE_MS:-100000}"
NODE_DISPLAY_NAME="${NODE_DISPLAY_NAME:-}"
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
  set_kv "$CFG" "ObserverCleanOldEpochsData"         "true"
  set_kv "$CFG" "AccountsTrieCleanOldEpochsData"     "true"
  set_kv "$CFG" "NumEpochsToKeep"                    "$NUM_EPOCHS_TO_KEEP"
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
EOF

# --- systemd units -----------------------------------------------------------
# The install writes these with *:DEBUG and appends $NODE_EXTRA_FLAGS. We want
# INFO (DEBUG dumps full SC payloads and floods the journal), and we must NOT
# carry -operation-mode historical-balances, which would disable pruning AND
# fast bootstrap.
echo
echo "-- systemd units"
UNIT_CHANGED=0
for n in $NODES; do
  U="/etc/systemd/system/elrond-node-$n.service"
  [ -f "$U" ] || { warn "$U missing"; continue; }
  BEFORE=$(md5sum "$U" | cut -d' ' -f1)
  sudo sed -i -E 's/-log-level \*:DEBUG/-log-level *:INFO/g; s/[[:space:]]*-operation-mode[[:space:]]+historical-balances//g' "$U"
  AFTER=$(md5sum "$U" | cut -d' ' -f1)
  [ "$BEFORE" != "$AFTER" ] && UNIT_CHANGED=1
  LINE=$(grep -E "^[[:space:]]*ExecStart=" "$U" | grep -v '#' | sed 's/^[[:space:]]*//')
  case "$LINE" in
    *"historical-balances"*) bad "node-$n still has historical-balances flag" ;;
    *"*:DEBUG"*)             bad "node-$n still at DEBUG" ;;
    *)                       ok "node-$n: $(echo "$LINE" | grep -o '\-log-level [^ ]*')" ;;
  esac
done
[ "$UNIT_CHANGED" -eq 1 ] && { sudo systemctl daemon-reload; ok "daemon-reload done"; }

# --- variables.cfg -----------------------------------------------------------
# NODE_EXTRA_FLAGS *is* one of the six fields github_pull preserves, so clearing
# it here stops a future observing_squad install from re-adding the flag.
echo
echo "-- variables.cfg"
if [ -f "$SCRIPTS_CFG" ]; then
  if grep -q "historical-balances" "$SCRIPTS_CFG"; then
    sed -i -E 's|^NODE_EXTRA_FLAGS=.*|NODE_EXTRA_FLAGS=""|' "$SCRIPTS_CFG"
    ok "NODE_EXTRA_FLAGS cleared (was historical-balances)"
  else
    ok "$(grep -E '^NODE_EXTRA_FLAGS=' "$SCRIPTS_CFG" || echo 'NODE_EXTRA_FLAGS not set')"
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
