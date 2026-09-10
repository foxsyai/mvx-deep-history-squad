#!/usr/bin/env bash
#
# mvx-thermal-cap.sh — keep a node box with degraded cooling fast AND safe.
#
#   apply   at boot: cap package POWER (RAPL), allow turbo
#   watch   every 30 s: if the package runs hot anyway, step power down
#   status  one line: limits, clock, temperature
#
# Why a power cap and not a frequency cap
# ---------------------------------------
# The first stopgap on these NUCs was `no_turbo=1`. On an i7-10710U that pins every core
# to its 1.1 GHz base clock. That was enough for 6-second rounds; after Supernova
# (600 ms rounds, ten times the blocks) it was not: on 2026-09-10 both 12-core boxes sat
# at 96-99 % CPU with 50-60 runnable threads, and the multikey backup's metachain fell
# behind at ~0.5 blocks/s.
#
# Heat is power. Capping package power (Intel RAPL) bounds exactly the thing that trips
# the hardware cutoff, while letting the chip run as fast as that budget allows. Setting
# the burst limit (PL2) equal to the sustained one (PL1) matters just as much: the stock
# 64 W bursts are what spiked a degraded NUC from 72 to 93 C in sixteen seconds.
#
# Measured at 12 W, turbo on, 4 minutes under full post-Supernova load:
#   home-sh012m  plateau 70-72 C, 1.5-2.1 GHz, metachain gap 379 -> 0 in 3 min
#   home-dh      cooler still (better cooling after cleaning)
#
# Config: /etc/default/mvx-thermal-cap
#   WATTS=12        sustained = burst power limit when healthy
#   SAFE_WATTS=8    what `watch` drops to if the package still runs hot
#   HOT_C=88        `watch` trip point
#
# The watch drop is sticky until the next `apply` (a reboot, or run it by hand): a limit
# that re-raises itself automatically would oscillate at the edge of the fault.

set -uo pipefail

[ -f /etc/default/mvx-thermal-cap ] && . /etc/default/mvx-thermal-cap
WATTS="${WATTS:-12}"; SAFE_WATTS="${SAFE_WATTS:-8}"; HOT_C="${HOT_C:-88}"

R=/sys/class/powercap/intel-rapl:0
P=/sys/devices/system/cpu/intel_pstate
TZ=""; for z in /sys/class/thermal/thermal_zone*; do [ "$(cat $z/type 2>/dev/null)" = x86_pkg_temp ] && TZ=$z/temp; done

set_power() { # set_power <watts>
  echo $(( $1 * 1000000 )) > $R/constraint_0_power_limit_uw   # PL1 sustained
  echo $(( $1 * 1000000 )) > $R/constraint_1_power_limit_uw   # PL2 burst = PL1
}
pl1() { echo $(( $(cat $R/constraint_0_power_limit_uw) / 1000000 )); }
temp() { echo $(( $(cat "$TZ") / 1000 )); }

alert() { # log to the journal, and Telegram if the history guard is configured
  logger -t mvx-thermal-cap "$1"; echo "$1"
  local c=/home/sebastian/.mvx-guard.conf
  if [ -f "$c" ]; then . "$c"
    [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && curl -s --max-time 10 -o /dev/null \
      "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
      --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" --data-urlencode "text=🌡 $(hostname -s): $1"
  fi
}

case "${1:-status}" in
  apply)
    [ -d "$R" ] || { echo "no RAPL package domain at $R"; exit 1; }
    set_power "$WATTS"
    echo 100 > $P/max_perf_pct
    echo 0   > $P/no_turbo
    # power-saver lowers the energy/performance preference below what the budget allows
    command -v powerprofilesctl >/dev/null && powerprofilesctl set balanced 2>/dev/null
    echo "applied: PL1=PL2=${WATTS}W turbo on (pkg $(temp)C)"
    ;;
  watch)
    t=$(temp); was=$(pl1)
    if [ "$t" -ge "$HOT_C" ] && [ "$was" -gt "$SAFE_WATTS" ]; then
      set_power "$SAFE_WATTS"
      alert "package ${t}C >= ${HOT_C}C at ${was}W - dropped power to ${SAFE_WATTS}W. Check cooling; run 'mvx-thermal-cap.sh apply' to restore."
    fi
    ;;
  status)
    printf "PL1=%sW PL2=%sW no_turbo=%s perf=%s%% freq=%sMHz pkg=%sC\n" \
      "$(pl1)" "$(( $(cat $R/constraint_1_power_limit_uw)/1000000 ))" "$(cat $P/no_turbo)" \
      "$(cat $P/max_perf_pct)" "$(( $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq)/1000 ))" "$(temp)"
    ;;
  *) echo "usage: $0 {apply|watch|status}" >&2; exit 2 ;;
esac
