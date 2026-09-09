#!/usr/bin/env bash
#
# mvx-fleet-maint.sh — routine OS maintenance + health report across a fleet of
# MultiversX node machines (observing squads, deep-history squads, single nodes).
#
#   survey    read-only pre-flight: OS, pending updates, node version, sync state
#   maintain  apt update/upgrade/autoremove -> graceful node stop -> reboot -> verify
#   report    resource + node-sync table (disk / RAM / CPU / gap)
#
# Hosts come from an inventory file that is deliberately NOT tracked in this repo
# (it holds addresses). Format, one machine per line:
#
#     name            user@host          nodes
#     do-sh0          deploy@203.0.113.1    1
#     observing-squad deploy@203.0.113.9    4
#
# Location: $MVX_FLEET_HOSTS, else ./fleet.hosts, else ~/.mvx-fleet.hosts
#
# Safe by design: `survey` and `report` never write. `maintain` reboots and is the
# only destructive mode; it stops nodes with systemctl first so LevelDB closes
# cleanly rather than being killed mid-write.

set -uo pipefail

RED=$'\033[0;31m'; GRN=$'\033[0;32m'; YLW=$'\033[0;33m'; CYN=$'\033[0;36m'; NC=$'\033[0m'

SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new)
BOOT_GRACE=${BOOT_GRACE:-90}     # seconds to let nodes bootstrap before reporting
REBOOT_WAIT=${REBOOT_WAIT:-360}  # max seconds to wait for a machine to come back

die() { echo "${RED}error:${NC} $*" >&2; exit 1; }

find_inventory() {
  local f
  for f in "${MVX_FLEET_HOSTS:-}" ./fleet.hosts "$HOME/.mvx-fleet.hosts"; do
    [ -n "$f" ] && [ -f "$f" ] && { echo "$f"; return; }
  done
  die "no inventory file found (set MVX_FLEET_HOSTS, or create ./fleet.hosts)"
}

# ---------------------------------------------------------------- remote probes

# Read-only snapshot. Printed as KEY: value lines.
remote_probe() {
cat <<'EOS'
echo "OS|$(lsb_release -ds 2>/dev/null || grep PRETTY /etc/os-release | cut -d'"' -f2)"
echo "KERNEL|$(uname -r)"
echo "KERNEL_NEW|$(ls -1 /boot/vmlinuz-* 2>/dev/null | sed 's|.*vmlinuz-||' | sort -V | tail -1)"
echo "UPTIME|$(uptime -p | sed 's/^up //')"
echo "REBOOT|$([ -f /var/run/reboot-required ] && echo REQUIRED || echo clear)"
echo "DISK|$(df -h / | tail -1 | awk '{print $4" free / "$2" ("$5" used)"}')"
echo "DISK_PCT|$(df -h / | tail -1 | awk '{print $5}' | tr -d '%')"
echo "RAM|$(free -h | awk '/^Mem:/{print $3" / "$2}')"
echo "RAM_PCT|$(free | awk '/^Mem:/{printf "%.0f", $3/$2*100}')"
echo "SWAP|$(free -h | awk '/^Swap:/{print $3" / "$2}')"
echo "LOAD|$(cut -d' ' -f1-3 /proc/loadavg)"
echo "CORES|$(nproc)"
if command -v apt-get >/dev/null 2>&1; then
  echo "UPGRADABLE|$(apt list --upgradable 2>/dev/null | grep -c upgradable)"
fi
for p in 8080 8081 8082 8083; do
  R=$(curl -s --max-time 5 "http://localhost:$p/node/status" 2>/dev/null)
  [ -z "$R" ] && continue
  echo "$R" | jq -r --arg p "$p" '.data.metrics |
    (if .erd_shard_id == 4294967295 then "meta" else (.erd_shard_id|tostring) end) as $s |
    "NODE|\($p)|\($s)|\(.erd_epoch_number)|\(.erd_nonce)|\((.erd_probable_highest_nonce // 0) - (.erd_nonce // 0))|\(.erd_is_syncing)|\(.erd_app_version)"' 2>/dev/null
done
EOS
}

# apt update / upgrade / autoremove. Keeps existing config files on conffile
# conflicts (--force-confold) so an unattended run can never hang on a prompt
# or silently replace a tuned config.
remote_maint() {
cat <<'EOS'
export DEBIAN_FRONTEND=noninteractive
echo "disk before: $(df -h / | tail -1 | awk '{print $4" free ("$5" used)"}')"
sudo -E apt-get update -qq 2>&1 | tail -3
PKGS=$(apt list --upgradable 2>/dev/null | grep upgradable | cut -d/ -f1 | tr '\n' ' ')
echo "to upgrade: ${PKGS:-<none>}"
sudo -E apt-get upgrade -y \
  -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold 2>&1 \
  | grep -E "^[0-9]+ upgraded|^E:|^W: " | tail -5
sudo -E apt-get autoremove -y 2>&1 | grep -E "^[0-9]+ upgraded|to remove|^E:" | tail -3
echo "disk after:  $(df -h / | tail -1 | awk '{print $4" free ("$5" used)"}')"
echo "reboot flag: $([ -f /var/run/reboot-required ] && echo REQUIRED || echo clear)"
echo "kernel: running $(uname -r) / newest $(ls -1 /boot/vmlinuz-* | sed 's|.*vmlinuz-||' | sort -V | tail -1)"
EOS
}

# Stop every running elrond unit so storage closes cleanly, then reboot.
remote_stop_reboot() {
cat <<'EOS'
for u in $(systemctl list-units --type=service --state=running --no-pager \
           | grep -oE "elrond-(node-[0-9]+|proxy)\.service"); do
  sudo systemctl stop "$u" && echo "stopped $u"
done
sleep 3
sudo nohup shutdown -r now >/dev/null 2>&1 &
echo "reboot issued"
EOS
}

# ------------------------------------------------------------------- utilities

probe_host() { ssh "${SSH_OPTS[@]}" "$1" 'bash -s' <<< "$(remote_probe)" 2>/dev/null; }

wait_for_host() {
  local target=$1 waited=0
  sleep 20; waited=20
  while [ $waited -lt "$REBOOT_WAIT" ]; do
    if ssh "${SSH_OPTS[@]}" -o ConnectTimeout=5 "$target" 'true' 2>/dev/null; then
      echo "$waited"; return 0
    fi
    sleep 6; waited=$((waited+6))
  done
  return 1
}

# field <data> <key> — pull one KEY|value line out of a probe result.
field() { echo "$1" | grep "^$2|" | head -1 | cut -d'|' -f2-; }

# Render one host's probe output as a report block.
render_report() {
  local name=$1 data=$2
  printf "%s%s%s\n" "$CYN" "$name" "$NC"
  printf "  os      %s (kernel %s)\n" "$(field "$data" OS)" "$(field "$data" KERNEL)"
  printf "  uptime  %s | reboot: %s\n" "$(field "$data" UPTIME)" "$(field "$data" REBOOT)"
  printf "  disk    %s\n" "$(field "$data" DISK)"
  printf "  ram     %s | swap %s\n" "$(field "$data" RAM)" "$(field "$data" SWAP)"
  printf "  cpu     %s cores | load %s\n" "$(field "$data" CORES)" "$(field "$data" LOAD)"
  echo "$data" | grep '^NODE|' | while IFS='|' read -r _ port shard epoch nonce gap syncing ver; do
    local flag="$GRN ok $NC"
    [ "$syncing" != "0" ] && flag="$YLW syncing $NC"
    [ "${gap:-0}" -gt 5 ] 2>/dev/null && flag="$YLW gap $gap $NC"
    printf "  node    :%s shard=%-4s epoch=%s nonce=%s gap=%s [%b]\n" \
      "$port" "$shard" "$epoch" "$nonce" "$gap" "$flag"
  done
}

# --------------------------------------------------------------------- actions

do_survey() {
  local name target
  while read -r name target _ <&3; do
    [ -z "${name:-}" ] && continue; case "$name" in \#*) continue;; esac
    echo
    local data; data=$(probe_host "$target")
    if [ -z "$data" ]; then echo "${RED}$name — UNREACHABLE${NC}"; continue; fi
    local upg; upg=$(echo "$data" | grep '^UPGRADABLE|' | cut -d'|' -f2)
    render_report "$name" "$data"
    printf "  apt     %s package(s) upgradable\n" "${upg:-?}"
  done 3< <(grep -vE '^\s*(#|$)' "$INV")
}

do_report() {
  echo
  echo "| machine | os | kernel | uptime | disk free | ram | cpu load | nodes ok |"
  echo "|---|---|---|---|---|---|---|---|"
  local name target
  while read -r name target _ <&3; do
    [ -z "${name:-}" ] && continue; case "$name" in \#*) continue;; esac
    local data; data=$(probe_host "$target")
    if [ -z "$data" ]; then echo "| $name | **UNREACHABLE** | | | | | | |"; continue; fi
    local total ok
    total=$(echo "$data" | grep -c '^NODE|')
    ok=$(echo "$data" | awk -F'|' '$1=="NODE" && $7=="0" && $6+0<=5' | wc -l)
    printf "| %s | %s | %s | %s | %s | %s | %s | %s/%s |\n" \
      "$name" "$(field "$data" OS)" "$(field "$data" KERNEL)" "$(field "$data" UPTIME)" \
      "$(field "$data" DISK)" "$(field "$data" RAM)" "$(field "$data" LOAD)" "$ok" "$total"
  done 3< <(grep -vE '^\s*(#|$)' "$INV")
}

do_maintain() {
  local name target
  while read -r name target _ <&3; do
    [ -z "${name:-}" ] && continue; case "$name" in \#*) continue;; esac
    echo
    echo "${CYN}=========== $name ===========${NC}"

    echo "-- 1. apt update / upgrade / autoremove"
    ssh "${SSH_OPTS[@]}" "$target" 'bash -s' <<< "$(remote_maint)" 2>&1 | sed 's/^/   /'

    echo "-- 2. graceful node stop + reboot"
    ssh "${SSH_OPTS[@]}" "$target" 'bash -s' <<< "$(remote_stop_reboot)" 2>&1 | sed 's/^/   /'

    echo "-- 3. waiting for return"
    local waited
    if ! waited=$(wait_for_host "$target"); then
      echo "   ${RED}did NOT come back within ${REBOOT_WAIT}s — stopping here${NC}"
      echo "   ${RED}investigate $name before continuing the fleet${NC}"
      return 1
    fi
    echo "   back after ~${waited}s"

    echo "-- 4. bootstrap grace ${BOOT_GRACE}s"
    sleep "$BOOT_GRACE"

    echo "-- 5. post-reboot health"
    local data; data=$(probe_host "$target")
    render_report "$name" "$data" | sed 's/^/   /'
  done 3< <(grep -vE '^\s*(#|$)' "$INV")
}

# ------------------------------------------------------------------------ main

ACTION=${1:-survey}
INV=$(find_inventory)
echo "inventory: $INV"

case "$ACTION" in
  survey)   do_survey ;;
  report)   do_report ;;
  maintain) do_maintain ;;
  *) die "unknown action '$ACTION' (want: survey | report | maintain)" ;;
esac
