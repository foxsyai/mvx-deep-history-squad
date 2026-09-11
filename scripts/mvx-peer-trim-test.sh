#!/usr/bin/env bash
#
# mvx-peer-trim-test.sh — the staged check to run before PEER_TRIM=on in mvx-epoch-prune.sh.
#
# Deleting history is irreversible, and in historical-balances mode a node that cannot
# start from its own disk replays from genesis. So validator statistics are never
# deleted on theory. Move one epoch's copy aside, prove nothing needed it, and only then
# let the nightly prune delete them. This is the same move-aside method that caught the
# epoch N-1 price dependency on 2026-09-11 (README §9.3a).
#
#   baseline         record staking-key count + price for epochs FIRST_EPOCH..current
#   move <epoch>     move that epoch's metachain PeerAccountsTrie into the quarantine
#   compare          re-run the queries; every answer must be identical to the baseline
#   restart          restart the metachain node; it must boot from disk and resync
#   status           what is in the quarantine and when it was moved
#   restore          put everything in the quarantine back
#   finish           delete the quarantine (refused until an epoch change has passed)
#
# Order: baseline -> move <e> -> compare -> restart -> compare -> (next epoch) -> finish
# Reads PROXY_URL, CAPTURE_SC, PROBE_SC, PROBE_FUNC, PROBE_ARGS from ~/.mvx-guard.conf.

set -uo pipefail
CONF="${MVX_GUARD_CONF:-$HOME/.mvx-guard.conf}"; [ -f "$CONF" ] && . "$CONF"
PROXY_URL="${PROXY_URL:-http://localhost:8079}"
NODES_ROOT="${NODES_ROOT:-$HOME/elrond-nodes}"
FIRST_EPOCH="${FIRST_EPOCH:-${PROBE_MIN_EPOCH:-2231}}"
Q="${PEER_QUARANTINE:-$HOME/peer-trim-quarantine}"
T="${SLOW_TIMEOUT:-180}"

die() { echo "ERROR: $*" >&2; exit 1; }
case "${1:-}" in baseline|compare)
  [ -n "${CAPTURE_SC:-}" ] && [ -n "${PROBE_SC:-}" ] && [ -n "${PROBE_FUNC:-}" ] \
    || die "CAPTURE_SC, PROBE_SC and PROBE_FUNC must be set in $CONF" ;;
esac
cur_epoch() { curl -s --max-time 10 localhost:8083/node/status | jq -r '.data.metrics.erd_epoch_number // empty'; }

# meta_node -> "<n>" of the node whose shard is the metachain
meta_node() {
  local n; for n in 0 1 2 3; do
    [ "$(curl -s --max-time 5 localhost:$((8080 + n))/node/status | jq -r '.data.metrics.erd_shard_id // empty')" = 4294967295 ] && { echo "$n"; return; }
  done
}

# probe <epoch> -> "staking=<keys> price=<base64>" — the monthly job's two calls
probe() {
  local n aj rd px
  n=$(curl -s --max-time 15 "$PROXY_URL/network/epoch-start/4294967295/by-epoch/$1" | jq -r '.data.epochStart.nonce // empty')
  [ -z "$n" ] && { echo "no-epoch-start"; return; }
  aj=$(printf '%s' "${PROBE_ARGS:-}" | jq -R 'split(",")')
  rd=$(curl -s --max-time "$T" "$PROXY_URL/address/$CAPTURE_SC/keys?blockNonce=$n" \
       | jq -r 'if ((.error//"")!="") then "FAIL" else (.data.pairs|length|tostring) end' 2>/dev/null)
  px=$(curl -s --max-time "$T" "$PROXY_URL/vm-values/query?blockNonce=$n" -H 'Content-Type: application/json' \
       -d "{\"scAddress\":\"$PROBE_SC\",\"funcName\":\"$PROBE_FUNC\",\"args\":$aj}" \
       | jq -r '.data.data.returnData[0] // "NONE"' 2>/dev/null)
  echo "staking=${rd:-TIMEOUT} price=${px:-TIMEOUT}"
}

probe_all() { # probe_all <last epoch>
  local e; for ((e = FIRST_EPOCH; e <= $1; e++)); do echo "$e $(probe $e)"; done
}

case "${1:-}" in
  baseline)
    c=$(cur_epoch); [ -n "$c" ] || die "cannot read current epoch"
    mkdir -p "$Q"; probe_all "$c" | tee "$Q/baseline.txt"
    grep -qE 'FAIL|NONE|TIMEOUT|no-epoch' "$Q/baseline.txt" && echo "WARNING: baseline has failures — fix those before testing"
    echo "baseline: epochs $FIRST_EPOCH..$c saved to $Q/baseline.txt" ;;

  move)
    e="${2:-}"; case "$e" in ''|*[!0-9]*) die "usage: $0 move <epoch>";; esac
    [ -f "$Q/baseline.txt" ] || die "run baseline first"
    c=$(cur_epoch); m=$(meta_node); [ -n "$c" ] && [ -n "$m" ] || die "cannot read epoch / find metachain node"
    nap=$(grep -hE '^\s*NumActivePersisters\s*=' "$NODES_ROOT/node-$m/config/config.toml" | tr -dc '0-9'); nap=${nap:-3}
    [ "$e" -lt $((c - nap + 1)) ] || die "epoch $e is among the $nap epochs node-$m keeps open (current $c)"
    src=$(ls -d "$NODES_ROOT/node-$m"/db/*/"Epoch_$e/Shard_metachain/PeerAccountsTrie" 2>/dev/null | head -1)
    [ -n "$src" ] || die "no PeerAccountsTrie for epoch $e on node-$m"
    pid=$(systemctl show -p MainPID --value "elrond-node-$m")
    ls -l "/proc/$pid/fd" 2>/dev/null | grep -q "Epoch_$e/Shard_metachain/PeerAccountsTrie" \
      && die "node-$m has files open in $src — not moving"
    [ "$(stat -c %d "$NODES_ROOT")" = "$(stat -c %d "$HOME")" ] || die "quarantine would cross filesystems"
    dst="$Q/node-$m/Epoch_$e/Shard_metachain"; mkdir -p "$dst"
    sz=$(du -sh "$src" | cut -f1)
    mv "$src" "$dst/" || die "move failed"
    echo "$e $c $(date -u +%FT%TZ) $src" >> "$Q/moved.txt"
    echo "moved $src ($sz) -> $dst/  (current epoch $c)" ;;

  compare)
    [ -f "$Q/baseline.txt" ] || die "no baseline"
    bad=0
    while read -r e rest; do
      now=$(probe "$e")
      if [ "$now" = "$rest" ]; then echo "$e SAME      $now"; else echo "$e DIFFERENT now: $now  was: $rest"; bad=1; fi
    done < "$Q/baseline.txt"
    [ $bad = 0 ] && echo "RESULT: all answers identical" || { echo "RESULT: MISMATCH — run: $0 restore"; exit 1; } ;;

  restart)
    m=$(meta_node); [ -n "$m" ] || die "cannot find metachain node"
    echo "restarting elrond-node-$m (metachain)"; since=$(date -u '+%Y-%m-%d %H:%M:%S')
    sudo -n systemctl restart "elrond-node-$m" || die "restart failed"
    start=$(date +%s); ok=0; prev=0
    while [ $(( $(date +%s) - start )) -lt 1200 ]; do
      sleep 15
      read -r sy gap nonce <<< "$(curl -s --max-time 5 localhost:$((8080 + m))/node/status | jq -r '.data.metrics | "\(.erd_is_syncing) \((.erd_probable_highest_nonce//0)-(.erd_nonce//0)) \(.erd_nonce//0)"' 2>/dev/null)"
      echo "  t+$(( $(date +%s) - start ))s syncing=${sy:-?} gap=${gap:-?} nonce=${nonce:-?}"
      if [ "${sy:-1}" = 0 ] && [ "${gap:-999}" -le 5 ] 2>/dev/null && [ "${nonce:-0}" -gt "$prev" ] && [ "$prev" -gt 0 ]; then
        ok=$((ok + 1)); [ $ok -ge 2 ] && break
      else ok=0; fi
      prev=${nonce:-0}
    done
    journalctl -u "elrond-node-$m" --since "$since UTC" --no-pager -q | grep -E 'Bootstrap +epoch|panic|genesis' | head -5 | cut -c1-160
    [ $ok -ge 2 ] && echo "RESULT: node-$m back in sync after $(( $(date +%s) - start ))s" \
                  || { echo "RESULT: node-$m NOT in sync within 1200s — consider: $0 restore, then restart again"; exit 1; } ;;

  status)
    [ -f "$Q/moved.txt" ] && { echo "moved (epoch  current-at-move  time  source):"; cat "$Q/moved.txt"; } || echo "nothing moved"
    [ -d "$Q" ] && echo "quarantine size: $(du -sh "$Q" | cut -f1)"; echo "current epoch: $(cur_epoch)" ;;

  restore)
    [ -f "$Q/moved.txt" ] || die "nothing to restore"
    while read -r e c t src; do
      m=$(echo "$src" | grep -oE 'node-[0-9]+' | head -1)
      [ -d "$src" ] && { mkdir -p "$Q/recreated"; mv "$src" "$Q/recreated/$m-Epoch_$e" && echo "set aside a recreated $src"; }
      mv "$Q/$m/Epoch_$e/Shard_metachain/PeerAccountsTrie" "$(dirname "$src")/" && echo "restored $src"
    done < "$Q/moved.txt"
    mv "$Q/moved.txt" "$Q/moved.restored.$(date +%s)"
    echo "restored. If the node had the recreated copy open, restart it: $0 restart" ;;

  finish)
    [ -f "$Q/moved.txt" ] || die "nothing moved"
    c=$(cur_epoch); last=$(awk '{print $2}' "$Q/moved.txt" | sort -n | tail -1)
    [ -n "$c" ] && [ "$c" -gt "$last" ] || [ "${2:-}" = --force ] \
      || die "no epoch change since the move (moved at $last, now $c) — wait for one, then compare again"
    rm -rf -- "$Q" && echo "quarantine deleted. Now set PEER_TRIM=on in $CONF" ;;

  *) sed -n '3,22p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
