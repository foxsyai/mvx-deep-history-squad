#!/bin/bash
# Phase 2, done safely.
#
# Lesson from node-3: switching to full-history/deep-history mode disables fast
# bootstrap ("fast bootstrap is disabled"). If db lacks a solid recent chain, the
# node bootstraps from the NETWORK and falls back to epoch 0 (genesis).
# So: only switch once the phase-1 node has CAUGHT UP to the tip, guaranteeing
# it can bootstrap from storage instead.
set -u

N="$1"
PORT=$((8080 + N))
D="$HOME/elrond-nodes/node-$N"
cd "$D" || exit 1

say() { echo "[$(date +%H:%M:%S)] node-$N: $*"; }

find_pid() {
  for p in $(pgrep -x node 2>/dev/null); do
    readlink "/proc/$p/exe" 2>/dev/null | grep -q "node-$N/node" && { echo "$p"; return; }
  done
}

toggle_dblookup() {  # $1 = from, $2 = to
  cp config/config.toml config/config.toml.work
  awk -v from="$1" -v to="$2" '
    /^\[DbLookupExtensions\]/ { inSec = 1 }
    /^\[/ && !/^\[DbLookupExtensions\]/ { inSec = 0 }
    { if (inSec && $0 ~ /Enabled[[:space:]]*=/) sub("Enabled[[:space:]]*=[[:space:]]*" from, "Enabled = " to); print }
  ' config/config.toml.work > config/config.toml
  rm -f config/config.toml.work
}

PID="$(find_pid)"
[ -n "$PID" ] || { say "ERROR: no phase-1 process running"; exit 1; }
say "watching phase-1 pid $PID until caught up to tip"

STABLE=0
for i in $(seq 1 480); do
  sleep 30
  kill -0 "$PID" 2>/dev/null || { say "ERROR: phase-1 process died"; exit 1; }
  R=$(curl -s --max-time 6 "http://localhost:$PORT/node/status")
  if echo "$R" | grep -q "node is starting"; then
    [ $((i % 10)) -eq 0 ] && say "  still bootstrapping ($((i * 30))s)"
    STABLE=0; continue
  fi
  NONCE=$(echo "$R" | jq -r '.data.metrics.erd_nonce // empty' 2>/dev/null)
  HIGH=$(echo "$R"  | jq -r '.data.metrics.erd_probable_highest_nonce // empty' 2>/dev/null)
  SYNC=$(echo "$R"  | jq -r '.data.metrics.erd_is_syncing // empty' 2>/dev/null)
  [ -n "$NONCE" ] && [ -n "$HIGH" ] || { STABLE=0; continue; }
  GAP=$((HIGH - NONCE))
  [ $((i % 5)) -eq 0 ] && say "  nonce=$NONCE high=$HIGH gap=$GAP syncing=$SYNC"
  if [ "$GAP" -le 10 ] && [ "$SYNC" = "0" ]; then STABLE=$((STABLE + 1)); else STABLE=0; fi
  if [ "$STABLE" -ge 3 ]; then say "CAUGHT UP at nonce $NONCE (gap $GAP)"; break; fi
done
[ "$STABLE" -ge 3 ] || { say "ERROR: timed out waiting for catch-up"; exit 1; }

say "stopping phase-1 node gracefully"
kill "$PID"
for i in $(seq 1 120); do kill -0 "$PID" 2>/dev/null || { say "exited after ${i}s"; break; }; sleep 1; done
kill -0 "$PID" 2>/dev/null && { say "ERROR: would not exit; aborting"; exit 1; }

SWITCH_NONCE="$NONCE"
say "PHASE 2: restoring DbLookupExtensions=true, starting deep-history service"
toggle_dblookup false true
sudo systemctl start "elrond-node-$N"

# Verify it resumed from storage rather than genesis
for i in $(seq 1 20); do
  sleep 15
  EP=$(sudo journalctl -u "elrond-node-$N" --no-pager -o cat --since "-3min" 2>/dev/null \
        | sed 's/\x1b\[[0-9;]*m//g' | grep -aoE 'Bootstrap +epoch = [0-9]+' | tail -1)
  [ -n "$EP" ] && break
done
say "bootstrap decision: ${EP:-unknown}"
case "$EP" in
  *"epoch = 0") say "FAIL: genesis fallback again" ;;
  *)            say "OK: resumed from storage (switch nonce $SWITCH_NONCE)" ;;
esac
say "epochs: $(ls -d db/*/Epoch_* 2>/dev/null | sed 's#.*/##' | sort -t_ -k2 -n | tr '\n' ' ')"
say "DONE"
