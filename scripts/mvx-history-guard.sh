#!/usr/bin/env bash
#
# mvx-history-guard.sh — keep a deep-history squad honest.
#
#   watch     every few minutes: is each node alive, synced, not restart-looping?
#   verify    daily: can it still ANSWER a historical query? (the silent failure)
#   capture   daily: save this epoch's snapshot to disk, independent of node health
#
# Why `verify` exists, and why `watch` is not enough
# --------------------------------------------------
# On 2026-09-07 a rebuilt node reported epoch 2230, gap=0, syncing=0 on all four
# shards — perfectly healthy by every ordinary check — while its historical
# smart-contract state was gone. A fast bootstrap had downloaded current state and
# skipped the blocks it missed, so the contract storage tries for the outage window
# (and for earlier epochs) were never written. Nothing noticed until a month-end job
# failed a day later.
#
# Sync status describes the TIP. It says nothing about the PAST. Only a real
# historical query does, so `verify` runs one against a block N epochs back and
# alerts if it errors.
#
# Config: $MVX_GUARD_CONF, else ~/.mvx-guard.conf (mode 600 — it holds a bot token).
#
#   PROXY_URL="http://localhost:8079"
#   FLEET_HOSTS="$HOME/.mvx-fleet.hosts"      # optional, for watch across machines
#   TELEGRAM_BOT_TOKEN="..."                  # optional; without it, log only
#   TELEGRAM_CHAT_ID="..."
#   PROBE_EPOCHS_BACK=30                      # how far back `verify` reaches
#   PROBE_SC="erd1..."                        # contract to execute (SC storage trie)
#   PROBE_FUNC="getAmountOut"
#   PROBE_ARGS="5745474c442d626434643739,0de0b6b3a7640000"
#   CAPTURE_DIR="$HOME/mvx-captures"
#   CAPTURE_SC="erd1..."                      # contract whose keys to snapshot
#
# Alerts are edge-triggered: you get one message when something breaks and one when
# it recovers, not a message every run.

set -uo pipefail

CONF="${MVX_GUARD_CONF:-$HOME/.mvx-guard.conf}"
[ -f "$CONF" ] && . "$CONF"

PROXY_URL="${PROXY_URL:-http://localhost:8079}"
PROBE_EPOCHS_BACK="${PROBE_EPOCHS_BACK:-30}"
GAP_LIMIT="${GAP_LIMIT:-50}"
STATE_DIR="${STATE_DIR:-$HOME/.mvx-guard-state}"
CAPTURE_DIR="${CAPTURE_DIR:-$HOME/mvx-captures}"
mkdir -p "$STATE_DIR"

log() { printf '[%s] %s\n' "$(date -u '+%Y-%m-%d %H:%M:%SZ')" "$*"; }

notify() { # notify <key> <ok|bad> <message>
  local key="$1" status="$2" msg="$3"
  local f="$STATE_DIR/$key" prev=""
  [ -f "$f" ] && prev=$(cat "$f")
  echo "$status" > "$f"
  [ "$status" = "$prev" ] && return 0          # edge-triggered: no repeat spam
  # first ever run: record the baseline, only shout if it is already broken
  [ -z "$prev" ] && [ "$status" = ok ] && return 0
  local text
  if [ "$status" = bad ]; then text="🔴 mvx-guard: $msg"; else text="✅ mvx-guard recovered: $msg"; fi
  log "$text"
  if [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && [ -n "${TELEGRAM_CHAT_ID:-}" ]; then
    curl -s --max-time 15 -o /dev/null \
      "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
      --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
      --data-urlencode "text=${text}" || log "(telegram send failed)"
  fi
}

api() { curl -s --max-time 15 "$@" 2>/dev/null; }

# ---------------------------------------------------------------------- watch

do_watch() {
  local bad=0 host_label="${1:-local}"
  for p in 8080 8081 8082 8083; do
    local r; r=$(api "http://localhost:$p/node/status")
    [ -z "$r" ] && continue
    local shard nonce high syncing
    shard=$(echo "$r"  | jq -r '.data.metrics.erd_shard_id // "?"')
    nonce=$(echo "$r"  | jq -r '.data.metrics.erd_nonce // 0')
    high=$(echo "$r"   | jq -r '.data.metrics.erd_probable_highest_nonce // 0')
    syncing=$(echo "$r"| jq -r '.data.metrics.erd_is_syncing // 1')
    local gap=$((high - nonce))
    [ "$gap" -lt 0 ] && gap=0
    if [ "$syncing" != "0" ] || [ "$gap" -gt "$GAP_LIMIT" ]; then
      notify "watch-$host_label-$p" bad "$host_label :$p shard=$shard behind (gap=$gap syncing=$syncing)"
      bad=1
    else
      notify "watch-$host_label-$p" ok "$host_label :$p shard=$shard synced"
    fi
  done
  # crash-looping units: NRestarts climbing between runs is the signal
  for i in 0 1 2 3; do
    local u="elrond-node-$i" act n prev pf
    systemctl list-unit-files "$u.service" >/dev/null 2>&1 || continue
    act=$(systemctl is-active "$u" 2>/dev/null)
    n=$(systemctl show "$u" -p NRestarts --value 2>/dev/null || echo 0)
    pf="$STATE_DIR/restarts-$u"; prev=$(cat "$pf" 2>/dev/null || echo "$n")
    echo "$n" > "$pf"
    if [ "$act" != "active" ]; then
      notify "unit-$u" bad "$u is $act"; bad=1
    elif [ "$n" -gt "$prev" ]; then
      notify "unit-$u" bad "$u restart-looping ($prev→$n)"; bad=1
    else
      notify "unit-$u" ok "$u active"
    fi
  done
  return $bad
}

# --------------------------------------------------------------------- verify
# The one that catches silent history loss.

do_verify() {
  local cur epoch target nonce
  cur=$(api "$PROXY_URL/network/status/4294967295" | jq -r '.data.status.erd_epoch_number // empty')
  [ -z "$cur" ] && cur=$(api "http://localhost:8083/node/status" | jq -r '.data.metrics.erd_epoch_number // empty')
  if [ -z "$cur" ]; then notify verify bad "cannot read current epoch"; return 1; fi

  target=$((cur - PROBE_EPOCHS_BACK))
  # Never probe earlier than the first epoch this node is expected to serve.
  # After a rebuild the node has no history before that point, and alerting daily
  # about damage that cannot be repaired is noise, not signal. Raise the floor
  # when you rebuild; the probe then covers only what SHOULD be intact.
  if [ -n "${PROBE_MIN_EPOCH:-}" ] && [ "$target" -lt "$PROBE_MIN_EPOCH" ]; then
    target="$PROBE_MIN_EPOCH"
  fi
  if [ "$target" -ge "$cur" ]; then
    log "verify: not enough history yet (floor $target >= current $cur) — skipping"
    return 0
  fi
  nonce=$(api "$PROXY_URL/network/epoch-start/4294967295/by-epoch/$target" | jq -r '.data.epochStart.nonce // empty')
  if [ -z "$nonce" ] || [ "$nonce" = null ]; then
    notify verify bad "no epoch-start record for epoch $target (history damaged)"
    return 1
  fi

  # 1. historical account read — needs the main accounts trie
  local acc
  acc=$(api "$PROXY_URL/address/${PROBE_SC:-}/keys?blockNonce=$nonce" | jq -r 'if ((.error//"")!="") then "ERR:"+.error else "ok" end')

  # 2. historical CONTRACT EXECUTION — needs the SC storage trie.
  #    This is the check that would have caught 2026-09-07; a balance read alone
  #    passes even when contract storage is gone.
  local vm="skipped"
  if [ -n "${PROBE_SC:-}" ] && [ -n "${PROBE_FUNC:-}" ]; then
    local args_json="[]"
    [ -n "${PROBE_ARGS:-}" ] && args_json=$(printf '%s' "$PROBE_ARGS" | jq -R 'split(",")')
    vm=$(api "$PROXY_URL/vm-values/query?blockNonce=$nonce" -H 'Content-Type: application/json' \
         -d "{\"scAddress\":\"$PROBE_SC\",\"funcName\":\"$PROBE_FUNC\",\"args\":$args_json}" \
         | jq -r 'if ((.error//"")!="") then "ERR:"+(.error|.[0:90]) else "ok" end')
  fi

  if [ "$vm" != ok ] && [ "$vm" != skipped ]; then
    notify verify bad "historical query FAILED at epoch $target (nonce $nonce): $vm"
    return 1
  fi
  if [ "$acc" != ok ]; then
    notify verify bad "historical account read failed at epoch $target: $acc"
    return 1
  fi
  notify verify ok "history intact at epoch $target (nonce $nonce)"
  log "verify: epoch $target nonce $nonce — account=$acc vm=$vm"
  return 0
}

# -------------------------------------------------------------------- capture
# Put the month's data on disk as it happens, so node health stops being a
# single point of failure for reporting.

do_capture() {
  local cur nonce out
  cur=$(api "http://localhost:8083/node/status" | jq -r '.data.metrics.erd_epoch_number // empty')
  [ -z "$cur" ] && { notify capture bad "cannot read current epoch"; return 1; }
  nonce=$(api "$PROXY_URL/network/epoch-start/4294967295/by-epoch/$cur" | jq -r '.data.epochStart.nonce // empty')
  if [ -z "$nonce" ] || [ "$nonce" = null ]; then
    notify capture bad "no epoch-start for current epoch $cur"; return 1
  fi

  out="$CAPTURE_DIR/$(date -u +%Y.%m)"; mkdir -p "$out"
  local ok=1
  if [ -n "${CAPTURE_SC:-}" ]; then
    api "$PROXY_URL/address/$CAPTURE_SC/keys?blockNonce=$nonce" > "$out/staking_${cur}.json"
    jq -e '.data.pairs' "$out/staking_${cur}.json" >/dev/null 2>&1 || ok=0
  fi
  if [ -n "${PROBE_SC:-}" ] && [ -n "${PROBE_FUNC:-}" ]; then
    local args_json="[]"
    [ -n "${PROBE_ARGS:-}" ] && args_json=$(printf '%s' "$PROBE_ARGS" | jq -R 'split(",")')
    api "$PROXY_URL/vm-values/query?blockNonce=$nonce" -H 'Content-Type: application/json' \
      -d "{\"scAddress\":\"$PROBE_SC\",\"funcName\":\"$PROBE_FUNC\",\"args\":$args_json}" \
      > "$out/price_${cur}.json"
    jq -e '.data.data.returnData' "$out/price_${cur}.json" >/dev/null 2>&1 || ok=0
  fi
  if [ "$ok" = 1 ]; then
    notify capture ok "captured epoch $cur to $out"
    log "capture: epoch $cur nonce $nonce -> $out"
  else
    notify capture bad "capture incomplete for epoch $cur — check $out"
    return 1
  fi
}

# ----------------------------------------------------------------------- floor
# "From which epoch is this node's history actually complete?"
#
# Walks the epochs on disk oldest->newest and reports, per epoch, whether the node
# can (a) resolve the epoch-start record, (b) READ state, (c) EXECUTE a contract.
# Those are three different capabilities and they fail independently — a squad
# without -operation-mode historical-balances reads far back and executes nowhere.
# Run it after any rebuild or mode change to learn the real floor, then set
# PROBE_MIN_EPOCH to it.

do_floor() {
  local step="${FLOOR_STEP:-5}" first_exec="" first_read=""
  local cur; cur=$(api "http://localhost:8083/node/status" | jq -r '.data.metrics.erd_epoch_number // empty')
  [ -z "$cur" ] && { echo "cannot read current epoch"; return 1; }
  local oldest
  oldest=$(ls "$HOME"/elrond-nodes/node-0/db/*/ -d 2>/dev/null | head -1)
  oldest=$(ls "$oldest" 2>/dev/null | grep -o 'Epoch_[0-9]*' | sed 's/Epoch_//' | sort -n | head -1)
  [ -z "$oldest" ] && oldest=$((cur - 60))
  echo "scanning epochs $oldest..$cur (step $step)"
  printf "%-8s %-12s %-10s %-8s %s\n" EPOCH NONCE EPOCH-REC READ EXEC
  local e
  for ((e=oldest; e<=cur; e+=step)); do
    local n rec rd ex
    n=$(api "$PROXY_URL/network/epoch-start/4294967295/by-epoch/$e" | jq -r '.data.epochStart.nonce // empty')
    if [ -z "$n" ] || [ "$n" = null ]; then
      printf "%-8s %-12s %-10s %-8s %s\n" "$e" "-" "MISSING" "-" "-"; continue
    fi
    rec=ok
    rd=$(api "$PROXY_URL/address/${PROBE_SC:-}/keys?blockNonce=$n" | jq -r 'if ((.error//"")!="") then "FAIL" else "ok" end')
    ex="n/a"
    if [ -n "${EXEC_SC:-}" ] && [ -n "${EXEC_FUNC:-}" ]; then
      local aj="[]"; [ -n "${EXEC_ARGS:-}" ] && aj=$(printf '%s' "$EXEC_ARGS" | jq -R 'split(",")')
      ex=$(api "$PROXY_URL/vm-values/query?blockNonce=$n" -H 'Content-Type: application/json' \
           -d "{\"scAddress\":\"$EXEC_SC\",\"funcName\":\"$EXEC_FUNC\",\"args\":$aj}" \
           | jq -r 'if ((.error//"")!="") then "FAIL" else "ok" end')
    fi
    [ "$rd" = ok ] && [ -z "$first_read" ] && first_read=$e
    [ "$ex" = ok ] && [ -z "$first_exec" ] && first_exec=$e
    printf "%-8s %-12s %-10s %-8s %s\n" "$e" "$n" "$rec" "$rd" "$ex"
  done
  echo
  echo "first epoch with working READ:      ${first_read:-none}"
  echo "first epoch with working EXECUTION: ${first_exec:-none}"
  echo "(set PROBE_MIN_EPOCH to the floor of whichever capability you rely on)"
}

# -------------------------------------------------------------------- report
# A once-a-day heartbeat, sent unconditionally.
#
# watch/verify are edge-triggered: they speak only when something changes, so a
# healthy fleet is silent. That is right for alerts and wrong as the ONLY signal,
# because silence is indistinguishable from "the guard itself stopped running" —
# a dead timer, a powered-off machine, a revoked bot token all look like calm.
# This sends a short digest every day, so no message IS the alarm.

do_report() {
  local lines="" bad=0 n
  for n in 0 1 2 3; do
    local p=$((8080 + n)) r shard ep gap sync
    r=$(api "http://localhost:$p/node/status")
    if [ -z "$r" ]; then lines="$lines"$'\n'"  node-$n: NO API"; bad=1; continue; fi
    shard=$(echo "$r" | jq -r '.data.metrics.erd_shard_id // "?"')
    [ "$shard" = "4294967295" ] && shard=meta
    ep=$(echo "$r"   | jq -r '.data.metrics.erd_epoch_number // "?"')
    sync=$(echo "$r" | jq -r '.data.metrics.erd_is_syncing // 1')
    gap=$(( $(echo "$r" | jq -r '.data.metrics.erd_probable_highest_nonce // 0') - $(echo "$r" | jq -r '.data.metrics.erd_nonce // 0') ))
    [ "$gap" -lt 0 ] && gap=0
    [ "$sync" != "0" ] && bad=1
    [ "$gap" -gt "$GAP_LIMIT" ] && bad=1
    lines="$lines"$'\n'"  shard $shard: epoch $ep, gap $gap$([ "$sync" != 0 ] && echo ' SYNCING')"
  done

  local disk win oldest newest d
  disk=$(df -h / | tail -1 | awk '{print $4" free ("$5" used)"}')
  d=$(ls -d "$HOME"/elrond-nodes/node-0/db/*/ 2>/dev/null | head -1)
  oldest=$(ls "$d" 2>/dev/null | grep -o 'Epoch_[0-9]*' | sed 's/Epoch_//' | sort -n | head -1)
  newest=$(ls "$d" 2>/dev/null | grep -o 'Epoch_[0-9]*' | sed 's/Epoch_//' | sort -n | tail -1)
  win="${oldest:-?}..${newest:-?}"

  # --- config drift -----------------------------------------------------------
  # An upgrade rewrites config/ wholesale and regenerates the systemd units. The
  # fix is to run mvx-deephistory-apply.sh before starting the nodes — a manual
  # step, and therefore one that eventually gets forgotten at an awkward hour.
  # Forgetting it is silent and expensive: NumEpochsToKeep reverts to 4 and prunes
  # the retention window away at the next epoch boundary. So check the settings
  # every day and say so, rather than trusting anyone to remember.
  local drift="" cfg="$HOME/elrond-nodes/node-0/config/config.toml"
  local want_hb="${HISTORICAL_BALANCES_EXPECTED:-1}" keep="${NUM_EPOCHS_EXPECTED:-62}"
  if [ -f "$cfg" ]; then
    local k; k=$(grep -hE "^\s*NumEpochsToKeep = " "$cfg" | head -1 | tr -dc '0-9')
    [ -n "$k" ] && [ "$k" != "$keep" ] && drift="$drift"$'\n'"  ⚠ NumEpochsToKeep=$k (expected $keep)"
    grep -qE "^\s*AccountsStatePruningEnabled = false" "$cfg" \
      || drift="$drift"$'\n'"  ⚠ AccountsStatePruningEnabled is not false"
  fi
  local units_hb; units_hb=$(grep -l "historical-balances" /etc/systemd/system/elrond-node-*.service 2>/dev/null | wc -l)
  if [ "$want_hb" = "1" ] && [ "$units_hb" != "4" ]; then
    drift="$drift"$'\n'"  ⚠ historical-balances on $units_hb/4 units — run mvx-deephistory-apply.sh"
  fi
  [ -n "$drift" ] && bad=1

  local head="✅ mvx daily report"; [ "$bad" = 1 ] && head="⚠️ mvx daily report (attention)"
  local text="$head — $(hostname -s)$lines
  window: $win
  disk: $disk${drift}"
  log "$text"
  if [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && [ -n "${TELEGRAM_CHAT_ID:-}" ]; then
    curl -s --max-time 15 -o /dev/null \
      "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
      --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
      --data-urlencode "text=${text}" || log "(telegram send failed)"
  fi
  return 0
}

case "${1:-watch}" in
  watch)   do_watch "$(hostname -s)" ;;
  verify)  do_verify ;;
  capture) do_capture ;;
  floor)   do_floor ;;
  report)  do_report ;;
  *) echo "usage: $0 {watch|verify|capture|floor|report}" >&2; exit 2 ;;
esac
