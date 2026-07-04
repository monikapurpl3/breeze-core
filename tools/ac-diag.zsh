#!/usr/bin/env zsh
#
# ac-diag.zsh — plain-text diagnostic tool for the meow-ac REST API.
#
# Reads /etc/meow-ac/config.json to find the API key and unit list, then
# talks to the running meow-ac service over HTTP the exact same way the
# web UI does. No forms, no colors, no boxes — just numbered menus and
# printed results.
#
# Usage:
#   ./ac-diag.zsh                        interactive menu
#   ./ac-diag.zsh --auto                 run full diagnostic on all units, no prompts
#   ./ac-diag.zsh --config /path.json    use a different config file
#   ./ac-diag.zsh --base-url http://...  point at a non-default host/port
#   ./ac-diag.zsh --with-control-test    also run the (harmless) control round-trip test
#                                         in --auto mode without asking first
#
# Needs: curl, jq (both standard on this system)
# Needs read access to config.json (mode 600, owned by meow-ac) — run
# with sudo, or add yourself to the meow-ac group and chmod 640 it.

emulate -L zsh
setopt err_return no_unset pipe_fail

CONFIG_PATH="${AC_CONFIG:-/etc/meow-ac/config.json}"
BASE_URL=""
AUTO_MODE=0
WITH_CONTROL_TEST=0
API_KEY=""

typeset -a UNIT_IDS UNIT_NAMES UNIT_IPS
typeset -i TOTAL_FAIL=0 TOTAL_WARN=0

# ---------------------------------------------------------------------
# small helpers — deliberately plain, no color codes, no box drawing
# ---------------------------------------------------------------------

ts() { print -n "[$(date '+%H:%M:%S')] " }
section() { print ""; ts; print "== $1 ==" }
info()    { ts; print "  $1" }
ok()      { ts; print "  OK      $1" }
warn()    { ts; print "  WARN    $1"; TOTAL_WARN+=1 }
fail()    { ts; print "  FAIL    $1"; TOTAL_FAIL+=1 }

die() { print "error: $1" >&2; exit 1 }

usage() {
  cat <<'EOF'
ac-diag.zsh — diagnostic tool for the meow-ac REST API

  --config PATH          path to config.json (default: /etc/meow-ac/config.json,
                          or $AC_CONFIG if set)
  --base-url URL         API base URL (default: http://127.0.0.1:8420)
  --auto                 run the full diagnostic on every unit, no menu
  --with-control-test    include the control round-trip test in --auto mode
                          without asking for confirmation first
  -h, --help             this text
EOF
}

# ---------------------------------------------------------------------
# argument parsing
# ---------------------------------------------------------------------

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config) CONFIG_PATH="$2"; shift 2 ;;
    --base-url) BASE_URL="$2"; shift 2 ;;
    --auto) AUTO_MODE=1; shift ;;
    --with-control-test) WITH_CONTROL_TEST=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) print "unknown argument: $1"; usage; exit 1 ;;
  esac
done

BASE_URL="${BASE_URL:-http://127.0.0.1:8420}"

# ---------------------------------------------------------------------
# dependency + config loading
# ---------------------------------------------------------------------

for bin in curl jq; do
  command -v "$bin" >/dev/null 2>&1 || die "$bin is required. Install with: sudo dnf install $bin"
done

load_config() {
  section "config"
  info "path: $CONFIG_PATH"

  [[ -e "$CONFIG_PATH" ]] || { fail "config not found at $CONFIG_PATH"; exit 1 }

  if [[ ! -r "$CONFIG_PATH" ]]; then
    fail "config exists but isn't readable by $(whoami) — try running this with sudo"
    exit 1
  fi
  ok "config file is readable"

  if ! jq empty "$CONFIG_PATH" >/dev/null 2>&1; then
    fail "config is not valid JSON"
    exit 1
  fi
  ok "config is valid JSON"

  API_KEY=$(jq -r '.api_key // empty' "$CONFIG_PATH")
  [[ -n "$API_KEY" ]] || { fail "no api_key found in config"; exit 1 }
  ok "api_key present (${#API_KEY} characters)"

  local unit_count
  unit_count=$(jq '.units | length' "$CONFIG_PATH")
  [[ "$unit_count" -gt 0 ]] || { fail "config has zero units"; exit 1 }
  ok "found $unit_count unit(s) in config"

  UNIT_IDS=("${(@f)$(jq -r '.units[].id' "$CONFIG_PATH")}")
  UNIT_NAMES=("${(@f)$(jq -r '.units[].name' "$CONFIG_PATH")}")
  UNIT_IPS=("${(@f)$(jq -r '.units[].ip' "$CONFIG_PATH")}")
}

# ---------------------------------------------------------------------
# HTTP helper — returns body/http_code/time_total via global vars
# so we don't fork subshells more than necessary
# ---------------------------------------------------------------------

REQ_BODY="" REQ_CODE="" REQ_TIME=""

http_req() {
  # http_req METHOD ENDPOINT [JSON_BODY]
  #
  # NOTE: the second local var below is deliberately NOT named "path" —
  # zsh ties a special array called $path directly to $PATH (same
  # family as fpath/FPATH, cdpath/CDPATH). Naming a local "path" here
  # silently destroys this function's command search path, which makes
  # curl, grep, cut — everything — report "command not found". Learned
  # that one the hard way; leaving this note so it doesn't come back.
  local method="$1" endpoint="$2" data="${3:-}"
  local raw
  if [[ -n "$data" ]]; then
    raw=$(curl -s -w $'\nHTTPSTATUS:%{http_code}\nTIMETOTAL:%{time_total}' \
      -X "$method" -H "X-API-Key: $API_KEY" -H "Content-Type: application/json" \
      -d "$data" "$BASE_URL$endpoint" 2>/dev/null) || true
  else
    raw=$(curl -s -w $'\nHTTPSTATUS:%{http_code}\nTIMETOTAL:%{time_total}' \
      -X "$method" -H "X-API-Key: $API_KEY" "$BASE_URL$endpoint" 2>/dev/null) || true
  fi
  REQ_CODE=$(print -r -- "$raw" | grep '^HTTPSTATUS:' | cut -d: -f2)
  REQ_TIME=$(print -r -- "$raw" | grep '^TIMETOTAL:' | cut -d: -f2)
  REQ_BODY=$(print -r -- "$raw" | grep -v '^HTTPSTATUS:' | grep -v '^TIMETOTAL:')
  [[ -n "$REQ_CODE" ]] || REQ_CODE="000"
}

ms_of() { # convert a curl time_total (seconds, e.g. 0.123) to whole ms, no forked processes
  local sec="${1:-0}"
  local ms=$(( sec * 1000 ))
  print -- "${ms%.*}"   # strip everything from the decimal point onward
}

# ---------------------------------------------------------------------
# tests
# ---------------------------------------------------------------------

check_connectivity() {
  section "connectivity"
  info "base url: $BASE_URL"
  http_req GET /api/units
  if [[ "$REQ_CODE" == "000" ]]; then
    fail "could not reach $BASE_URL at all — is meow-ac running? (systemctl status meow-ac)"
    exit 1
  fi
  ok "server is reachable (http $REQ_CODE in $(ms_of $REQ_TIME) ms)"
}

check_auth() {
  section "authentication"

  local saved_key="$API_KEY"

  API_KEY=""
  http_req GET /api/units
  [[ "$REQ_CODE" == "401" ]] && ok "request with no key correctly rejected (401)" \
    || fail "request with no key returned $REQ_CODE, expected 401"

  API_KEY="definitely-not-the-real-key"
  http_req GET /api/units
  [[ "$REQ_CODE" == "401" ]] && ok "request with wrong key correctly rejected (401)" \
    || fail "request with wrong key returned $REQ_CODE, expected 401"

  API_KEY="$saved_key"
  http_req GET /api/units
  [[ "$REQ_CODE" == "200" ]] && ok "request with correct key succeeded (200)" \
    || fail "request with correct key returned $REQ_CODE, expected 200"
}

check_units_listing() {
  section "unit listing"
  http_req GET /api/units
  if [[ "$REQ_CODE" != "200" ]]; then
    fail "GET /api/units returned $REQ_CODE"
    return
  fi
  local returned=$(print -r -- "$REQ_BODY" | jq 'length')
  local expected=${#UNIT_IDS[@]}
  if [[ "$returned" == "$expected" ]]; then
    ok "API reports $returned unit(s), matches config"
  else
    fail "API reports $returned unit(s), config has $expected — service may need a restart"
  fi
}

# full diagnostic for a single unit, by index into the UNIT_* arrays
diagnose_unit() {
  local idx="$1"
  local id="${UNIT_IDS[$idx]}" name="${UNIT_NAMES[$idx]}" ip="${UNIT_IPS[$idx]}"

  section "unit: $name  (id=$id, ip=$ip)"

  # --- reachability ---
  http_req GET "/api/units/$id/state"
  if [[ "$REQ_CODE" != "200" ]]; then
    fail "GET state returned $REQ_CODE — unit unreachable or misconfigured"
    return
  fi
  ok "state fetched (http 200, $(ms_of $REQ_TIME) ms)"

  local online power mode target indoor outdoor fan swing eco turbo
  online=$(print -r -- "$REQ_BODY" | jq -r '.online')
  power=$(print -r -- "$REQ_BODY" | jq -r '.power_state')
  mode=$(print -r -- "$REQ_BODY" | jq -r '.operational_mode')
  target=$(print -r -- "$REQ_BODY" | jq -r '.target_temperature')
  indoor=$(print -r -- "$REQ_BODY" | jq -r '.indoor_temperature')
  outdoor=$(print -r -- "$REQ_BODY" | jq -r '.outdoor_temperature')
  fan=$(print -r -- "$REQ_BODY" | jq -r '.fan_speed')
  swing=$(print -r -- "$REQ_BODY" | jq -r '.swing_mode')
  eco=$(print -r -- "$REQ_BODY" | jq -r '.eco')
  turbo=$(print -r -- "$REQ_BODY" | jq -r '.turbo')

  info "online=$online power=$power mode=$mode target=${target}C"
  info "indoor=${indoor}C outdoor=${outdoor}C fan=$fan swing=$swing eco=$eco turbo=$turbo"

  [[ "$online" == "true" ]] && ok "unit reports online" || warn "unit reports offline"

  # sanity-check the numbers actually look like temperatures
  if [[ "$target" != "null" ]] && (( target >= 16 && target <= 30 )); then
    ok "target_temperature ($target) within expected 16-30 range"
  else
    warn "target_temperature ($target) looks out of range"
  fi

  [[ "$indoor" == "null" ]] && warn "indoor_temperature is null — sensor reading unavailable" \
    || ok "indoor_temperature reading present ($indoor C)"

  case "$mode" in
    AUTO|COOL|DRY|HEAT|FAN_ONLY) ok "operational_mode ($mode) is a recognised value" ;;
    *) warn "operational_mode ($mode) is not one of the documented values" ;;
  esac

  case "$swing" in
    OFF|VERTICAL|HORIZONTAL|BOTH) ok "swing_mode ($swing) is a recognised value" ;;
    *) warn "swing_mode ($swing) is not one of the documented values" ;;
  esac

  # --- latency, repeated, to show what's inherent network round-trip
  # time vs one-off connection setup cost ---
  info "running 5x state fetches to check round-trip latency..."
  local -a samples
  local i sum=0
  for i in {1..5}; do
    http_req GET "/api/units/$id/state"
    if [[ "$REQ_CODE" == "200" ]]; then
      local m=$(ms_of $REQ_TIME)
      samples+=("$m")
      sum=$(( sum + m ))
    fi
  done
  if (( ${#samples[@]} > 0 )); then
    local avg=$(( sum / ${#samples[@]} ))
    info "samples (ms): ${samples[*]}   avg: ${avg} ms"
    if (( avg < 500 )); then
      ok "average round-trip is $avg ms — normal for a LAN device"
    else
      warn "average round-trip is $avg ms — slower than expected, check WiFi signal to this unit"
    fi
  else
    fail "none of the 5 repeat requests succeeded"
  fi

  # --- optional control round-trip test ---
  local run_control_test=0
  if [[ "$AUTO_MODE" == "1" ]]; then
    [[ "$WITH_CONTROL_TEST" == "1" ]] && run_control_test=1
  else
    print "  Run a live control round-trip test on this unit? It re-sends its"
    print "  current target_temperature unchanged — it will NOT change how the unit is running."
    print -n "  [y/N] "
    local answer=""
    read answer
    [[ "$answer" == [yY] || "$answer" == [yY][eE][sS] ]] && run_control_test=1
  fi

  if [[ "$run_control_test" == "1" ]]; then
    if [[ "$online" != "true" ]]; then
      warn "skipping control test — unit reports offline"
    else
      info "sending control request with unchanged target_temperature=$target ..."
      http_req POST "/api/units/$id/control" "{\"target_temperature\": $target}"
      if [[ "$REQ_CODE" != "200" ]]; then
        fail "control request returned $REQ_CODE"
      else
        local echoed=$(print -r -- "$REQ_BODY" | jq -r '.target_temperature')
        if [[ "$echoed" == "$target" ]]; then
          ok "control round-trip confirmed ($(ms_of $REQ_TIME) ms) — API can command this unit"
        else
          warn "control accepted but target_temperature came back as $echoed, expected $target"
        fi
      fi
    fi
  else
    info "control round-trip test skipped"
  fi
}

# ---------------------------------------------------------------------
# menu-driven modes
# ---------------------------------------------------------------------

print_unit_list() {
  local i
  for i in {1..${#UNIT_IDS[@]}}; do
    print "  $i) ${UNIT_NAMES[$i]}  (${UNIT_IPS[$i]}, id=${UNIT_IDS[$i]})"
  done
}

run_all_units() {
  local i
  for i in {1..${#UNIT_IDS[@]}}; do
    diagnose_unit "$i"
  done
}

print_summary() {
  section "summary"
  info "warnings: $TOTAL_WARN   failures: $TOTAL_FAIL"
  if (( TOTAL_FAIL > 0 )); then
    info "result: PROBLEMS FOUND"
  elif (( TOTAL_WARN > 0 )); then
    info "result: OK, WITH WARNINGS"
  else
    info "result: ALL CHECKS PASSED"
  fi
}

interactive_menu() {
  while true; do
    print ""
    print "meow-ac diagnostic — $(( ${#UNIT_IDS[@]} )) unit(s) configured"
    print "  1) list configured units"
    print "  2) run full diagnostic on one unit"
    print "  3) run full diagnostic on ALL units (automatic)"
    print "  4) config + auth check only"
    print "  5) exit"
    print -n "choice: "
    read choice
    case "$choice" in
      1) print_unit_list ;;
      2)
        print_unit_list
        print -n "unit number: "
        read n
        if [[ "$n" =~ '^[0-9]+$' ]] && (( n >= 1 && n <= ${#UNIT_IDS[@]} )); then
          diagnose_unit "$n"
          print_summary
        else
          print "not a valid unit number"
        fi
        ;;
      3)
        run_all_units
        print_summary
        ;;
      4)
        check_connectivity
        check_auth
        check_units_listing
        print_summary
        ;;
      5) exit 0 ;;
      *) print "not a valid choice" ;;
    esac
  done
}

# ---------------------------------------------------------------------
# entry point
# ---------------------------------------------------------------------

load_config
check_connectivity
check_auth
check_units_listing

if [[ "$AUTO_MODE" == "1" ]]; then
  run_all_units
  print_summary
  (( TOTAL_FAIL == 0 ))
  exit $?
else
  interactive_menu
fi
