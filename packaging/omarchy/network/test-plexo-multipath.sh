#!/usr/bin/env bash
# Tests sync_pins() in plexo-multipath without root and without touching the
# live routing table: `ip` is stubbed, so every call it would make is recorded
# and asserted instead of executed.
#
#   packaging/omarchy/network/test-plexo-multipath.sh
#
# The cases cover what the pin table has to survive: a mix of live flows and
# flows that ended, a peer that is the gateway itself, no flows at all, and a
# host with no `ss` to take a snapshot with.
set -euo pipefail

HELPER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/plexo-multipath"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# The script runs its argument parser at the bottom of the file; keep only the
# function definitions so a case can call sync_pins directly.
awk '/^case /{exit} {print}' "$HELPER" >"$TMP/prelude.sh"

cat >"$TMP/ip" <<'STUB'
#!/usr/bin/env bash
printf 'IP %s\n' "$*" >>"$IP_LOG"
case "$*" in
  "-4 route show proto 89") cat "$IP_TABLE" 2>/dev/null ;;
esac
STUB
chmod +x "$TMP/ip"

# The driver runs under `set -eu` on purpose: the helper only declares `set -u`
# today, but every `test ... && action` would abort the script if it ever gained
# `set -e`, so sync_pins has to stay safe under the stricter mode.
cat >"$TMP/driver.sh" <<'DRIVER'
set -eu
source "$PRELUDE"
IP="$FAKE_IP"
SS="$SS_MODE"
pin_rows() { cat "$ROWS_FILE"; }
sync_pins
DRIVER

FAIL=0
note() { printf '%s\n' "$*"; }
ok()   { note "  ok   $*"; }
bad()  { FAIL=1; note "  FAIL $*"; }

# table: the routes the script owns right now.
table() { printf '%s\n' "$@" >"$TMP/table"; }
# rows: what pin_rows() reports as live, "peer<TAB>dev<TAB>via<TAB>src".
row() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >>"$TMP/rows"; }

run_case() {
  local name="$1" ss="$2"
  : >"$TMP/calls"
  PRELUDE="$TMP/prelude.sh" FAKE_IP="$TMP/ip" SS_MODE="$ss" \
    ROWS_FILE="$TMP/rows" IP_LOG="$TMP/calls" IP_TABLE="$TMP/table" \
    bash "$TMP/driver.sh" || { bad "$name: sync_pins exited non-zero"; return; }
  note "case: $name"
}

expect() { if grep -qxF -- "$2" "$TMP/calls"; then ok "$1"; else bad "$1 (missing: $2)"; fi; }
reject() { if grep -qxF -- "$2" "$TMP/calls"; then bad "$1 (unexpected: $2)"; else ok "$1"; fi; }

# --- case 1: live flows kept, ended flows pruned, gateway self-pin dropped ----
: >"$TMP/rows"
row 1.1.1.1       wlp1s0 192.168.1.1 192.168.1.108
row 104.20.39.252 wlp1s0 192.168.1.1 192.168.1.108
row 192.168.1.1   wlp1s0 192.168.1.1 192.168.1.108
table "1.0.0.1 via 192.168.1.1 dev wlp1s0 proto 89 src 192.168.1.108" \
      "1.1.1.1 via 192.168.1.1 dev wlp1s0 proto 89 src 192.168.1.108" \
      "3.164.195.106 via 192.168.1.1 dev wlp1s0 proto 89 src 192.168.1.108" \
      "104.20.39.252 via 192.168.1.1 dev wlp1s0 proto 89 src 192.168.1.108" \
      "192.168.1.1 via 192.168.1.1 dev wlp1s0 proto 89 src 192.168.1.108"
run_case "mixed live and ended flows" ss
expect "live peer 1.1.1.1 is pinned" "IP route replace 1.1.1.1/32 proto 89 via 192.168.1.1 dev wlp1s0 src 192.168.1.108"
expect "live peer 104.20.39.252 is pinned" "IP route replace 104.20.39.252/32 proto 89 via 192.168.1.1 dev wlp1s0 src 192.168.1.108"
reject "gateway is never pinned (via itself)" "IP route replace 192.168.1.1/32 proto 89 via 192.168.1.1 dev wlp1s0 src 192.168.1.108"
expect "ended flow 1.0.0.1 is pruned" "IP route del 1.0.0.1/32 proto 89"
expect "ended flow 3.164.195.106 is pruned" "IP route del 3.164.195.106/32 proto 89"
expect "stale gateway pin is pruned" "IP route del 192.168.1.1/32 proto 89"
reject "live peer 104.20.39.252 is not pruned" "IP route del 104.20.39.252/32 proto 89"

# --- case 2: no ss, so no snapshot, so nothing may be pruned -----------------
: >"$TMP/rows"
row 1.1.1.1 wlp1s0 192.168.1.1 192.168.1.108
table "1.0.0.1 via 192.168.1.1 dev wlp1s0 proto 89 src 192.168.1.108"
run_case "no ss means no prune" ""
expect "pins are still installed" "IP route replace 1.1.1.1/32 proto 89 via 192.168.1.1 dev wlp1s0 src 192.168.1.108"
reject "no route table read" "IP -4 route show proto 89"
reject "no pin deleted" "IP route del 1.0.0.1/32 proto 89"

# --- case 3: nothing established, so every pin is dead weight ---------------
: >"$TMP/rows"
table "1.0.0.1 via 192.168.1.1 dev wlp1s0 proto 89 src 192.168.1.108" \
      "20.204.245.84 via 192.168.1.1 dev wlp1s0 proto 89 src 192.168.1.108"
run_case "no live flows" ss
expect "first dead pin pruned" "IP route del 1.0.0.1/32 proto 89"
expect "second dead pin pruned" "IP route del 20.204.245.84/32 proto 89"
reject "nothing pinned" "IP route replace 1.0.0.1/32 proto 89 via 192.168.1.1 dev wlp1s0 src 192.168.1.108"

if [[ "$FAIL" == 0 ]]; then
  note "all sync_pins cases passed"
else
  note "some sync_pins cases failed"
  exit 1
fi
