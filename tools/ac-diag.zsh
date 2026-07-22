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
#   ./ac-diag.zsh --unit ID|NAME         diagnose just one unit, non-interactively
#   ./ac-diag.zsh --with-control-test    also run the (harmless) control round-trip test
#                                         in --auto mode without asking first
#   ./ac-diag.zsh --token TOKEN          use this device token for the control API
#   ./ac-diag.zsh --pair                 (re)enrol this tool on the LAN to get a token
#   ./ac-diag.zsh --no-pair              never self-enrol; skip token-gated checks
#   ./ac-diag.zsh --forget-token         delete the cached device token and exit
#
# Control routes (/api/units*) and the config/programs routes need BOTH the
# API key AND a per-device token on a hardened server. This tool reads the key
# from config.json and, if it has no token, self-enrols on the LAN (start →
# approve → poll, all key-authenticated) and caches the token under
# ${XDG_CONFIG_HOME:-~/.config}/ac-diag/token. Override with --token / $AC_DIAG_TOKEN.
# The minted token shows up as "ac-diag" in `ac-approve list` and is revocable.
#
# Needs: curl, jq (both standard on this system)
# Needs read access to config.json. As of Breeze Core 2.4.3 it's mode 640, so
# add yourself to the service group (e.g. `sudo usermod -aG meow-ac $USER`,
# then re-login) and run this WITHOUT sudo — don't sudo a shell alias.

emulate -L zsh
setopt err_return no_unset pipe_fail

CONFIG_PATH="${AC_CONFIG:-/etc/meow-ac/config.json}"
BASE_URL=""
AUTO_MODE=0
WITH_CONTROL_TEST=0
API_KEY=""

# Device token (for the token-gated control/config/programs routes). Sourced
# from --token, then $AC_DIAG_TOKEN, then the cache file; or minted by
# self-enrolling on the LAN. Cache path honours XDG.
DEVICE_TOKEN="${AC_DIAG_TOKEN:-}"
TOKEN_CACHE="${XDG_CONFIG_HOME:-$HOME/.config}/ac-diag/token"
PAIR_MODE=0          # --pair: force a fresh self-enrollment
NO_PAIR=0            # --no-pair: never self-enroll (skip token-gated checks)
FORGET_TOKEN=0       # --forget-token: delete the cached token and exit
ONLY_UNIT=""         # --unit ID|NAME: diagnose just this one, non-interactively

# Filled in by check_version; used to feature-gate later checks.
SERVER_VERSION="" SERVER_COMMIT="" SERVER_FEATURES=""
# 1 once we can reach the token-gated unit routes (paired, or a key-only server).
UNIT_AUTH_OK=0
KEY_ONLY=0           # 1 if the server accepts the key alone (older/loosened build)

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
  --unit ID|NAME         diagnose just one unit (non-interactive)
  --with-control-test    include the control round-trip test in --auto mode
                          without asking for confirmation first
  --token TOKEN          device token for the control API (else $AC_DIAG_TOKEN,
                          else the cache file, else self-enrol on the LAN)
  --pair                 force a fresh self-enrolment to (re)mint a token
  --no-pair              never self-enrol; skip token-gated checks
  --forget-token         delete the cached device token and exit
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
    --unit) ONLY_UNIT="$2"; shift 2 ;;
    --with-control-test) WITH_CONTROL_TEST=1; shift ;;
    --token) DEVICE_TOKEN="$2"; shift 2 ;;
    --pair) PAIR_MODE=1; shift ;;
    --no-pair) NO_PAIR=1; shift ;;
    --forget-token) FORGET_TOKEN=1; shift ;;
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
  # Build the header list. The API key gates enrollment; control routes
  # (/api/units*) and full-auth routes (/api/config, /api/programs) also want
  # the per-device bearer token, so send it whenever we have one.
  local -a hdr
  hdr=(-H "X-API-Key: $API_KEY")
  [[ -n "$DEVICE_TOKEN" ]] && hdr+=(-H "Authorization: Bearer $DEVICE_TOKEN")
  if [[ -n "$data" ]]; then
    raw=$(curl -s -w $'\nHTTPSTATUS:%{http_code}\nTIMETOTAL:%{time_total}' \
      -X "$method" "${hdr[@]}" -H "Content-Type: application/json" \
      -d "$data" "$BASE_URL$endpoint" 2>/dev/null) || true
  else
    raw=$(curl -s -w $'\nHTTPSTATUS:%{http_code}\nTIMETOTAL:%{time_total}' \
      -X "$method" "${hdr[@]}" "$BASE_URL$endpoint" 2>/dev/null) || true
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
# device token: load / save / self-enrol on the LAN
# ---------------------------------------------------------------------

has_feature() { [[ " $SERVER_FEATURES " == *" $1 "* ]] }   # did /api/version advertise it?

load_token_cache() {
  [[ -n "$DEVICE_TOKEN" ]] && return 0        # --token / env wins
  if [[ -r "$TOKEN_CACHE" ]]; then
    DEVICE_TOKEN="$(<"$TOKEN_CACHE")"
    DEVICE_TOKEN="${DEVICE_TOKEN//[$'\n\r\t ']/}"
  fi
  return 0
}

save_token() {
  local tok="$1" dir="${TOKEN_CACHE:h}"
  mkdir -p "$dir" 2>/dev/null || return 0
  print -r -- "$tok" > "$TOKEN_CACHE" 2>/dev/null || return 0
  chmod 600 "$TOKEN_CACHE" 2>/dev/null || true
}

forget_token() {
  if [[ -e "$TOKEN_CACHE" ]]; then
    rm -f "$TOKEN_CACHE" && print "removed cached device token: $TOKEN_CACHE"
  else
    print "no cached device token at $TOKEN_CACHE"
  fi
}

# start -> approve -> poll, all key-authenticated; approve also needs a
# private-network client (which we are). Sets DEVICE_TOKEN on success.
pair_device() {
  section "device pairing"
  info "self-enrolling as 'ac-diag' to obtain a device token (LAN admin action)..."

  http_req POST /api/auth/enroll/start '{"label":"ac-diag"}'
  if [[ "$REQ_CODE" != "200" ]]; then fail "enroll/start returned $REQ_CODE — cannot pair"; return 1; fi
  local sid code
  sid=$(print -r -- "$REQ_BODY" | jq -r '.session_id // empty')
  code=$(print -r -- "$REQ_BODY" | jq -r '.user_code // empty')
  if [[ -z "$sid" || -z "$code" ]]; then fail "enroll/start returned no session/code"; return 1; fi
  info "got one-time code $code — approving from this host..."

  http_req POST /api/auth/enroll/approve "{\"code\":\"$code\"}"
  case "$REQ_CODE" in
    200) : ;;
    403) fail "approve returned 403 — approval must originate on the LAN; run this on the server or a private-network host"; return 1 ;;
    *)   fail "approve returned $REQ_CODE ($(print -r -- "$REQ_BODY" | jq -r '.detail // empty'))"; return 1 ;;
  esac

  local tries=0 st=""
  while (( tries < 10 )); do
    http_req POST /api/auth/enroll/poll "{\"session_id\":\"$sid\"}"
    st=$(print -r -- "$REQ_BODY" | jq -r '.status // empty')
    if [[ "$st" == "approved" ]]; then
      DEVICE_TOKEN=$(print -r -- "$REQ_BODY" | jq -r '.device_token // empty')
      if [[ -n "$DEVICE_TOKEN" ]]; then
        save_token "$DEVICE_TOKEN"
        ok "paired — device token acquired (cached at $TOKEN_CACHE, shows as 'ac-diag' in ac-approve list)"
        return 0
      fi
    fi
    tries=$(( tries + 1 ))
    sleep 1
  done
  fail "pairing did not complete (last status: ${st:-none})"
  return 1
}

# Ensure the token-gated unit routes are reachable; sets UNIT_AUTH_OK / KEY_ONLY.
ensure_unit_auth() {
  section "control-api authorization"
  if [[ "$PAIR_MODE" == "1" ]]; then
    DEVICE_TOKEN=""; rm -f "$TOKEN_CACHE" 2>/dev/null || true
    info "--pair given: discarding any cached token and re-enrolling"
  fi

  # Does the API key ALONE open /api/units? (older / loosened builds)
  local saved="$DEVICE_TOKEN"
  DEVICE_TOKEN=""
  http_req GET /api/units
  DEVICE_TOKEN="$saved"
  if [[ "$REQ_CODE" == "200" ]]; then
    KEY_ONLY=1; UNIT_AUTH_OK=1
    warn "server accepts the API key WITHOUT a device token — control API is not token-gated (older/loosened build)"
    return 0
  fi

  if [[ -n "$DEVICE_TOKEN" ]]; then
    http_req GET /api/units
    if [[ "$REQ_CODE" == "200" ]]; then ok "device token accepted — control API reachable"; UNIT_AUTH_OK=1; return 0; fi
    warn "the provided/cached device token was rejected ($REQ_CODE) — discarding and re-pairing"
    DEVICE_TOKEN=""
  fi

  if [[ "$NO_PAIR" == "1" ]]; then
    warn "no device token and --no-pair set — skipping unit / config / programs checks"
    return 0
  fi

  if pair_device; then
    http_req GET /api/units
    if [[ "$REQ_CODE" == "200" ]]; then ok "control API reachable with the freshly-minted token"; UNIT_AUTH_OK=1; return 0; fi
    warn "still cannot reach /api/units after pairing ($REQ_CODE)"
  fi
  warn "no working device token — token-gated checks will be skipped"
  return 0
}

# ---------------------------------------------------------------------
# tests
# ---------------------------------------------------------------------

check_version() {
  section "server version & build"
  http_req GET /api/health
  if [[ "$REQ_CODE" == "200" ]]; then
    ok "/api/health OK (status=$(print -r -- "$REQ_BODY" | jq -r '.status // "?"'))"
  else
    warn "/api/health returned $REQ_CODE (server may predate 2.4.0)"
  fi
  http_req GET /api/version
  if [[ "$REQ_CODE" != "200" ]]; then
    warn "/api/version returned $REQ_CODE — cannot read build info (server < 2.4.0?)"
    return
  fi
  SERVER_VERSION=$(print -r -- "$REQ_BODY" | jq -r '.version // "?"')
  SERVER_COMMIT=$(print -r -- "$REQ_BODY" | jq -r '.commit // "unknown"')
  SERVER_FEATURES=$(print -r -- "$REQ_BODY" | jq -r '(.features // []) | join(" ")')
  local units=$(print -r -- "$REQ_BODY" | jq -r '.units // "?"')
  ok "Breeze Core $SERVER_VERSION (commit $SERVER_COMMIT); server sees $units unit(s)"
  info "features: ${SERVER_FEATURES:-none advertised}"
}

check_config_security() {
  section "config API (secret sanitisation)"
  if ! has_feature config_api; then info "server doesn't advertise config_api — skipping"; return; fi
  http_req GET /api/config
  case "$REQ_CODE" in
    200)
      local leaks
      leaks=$(print -r -- "$REQ_BODY" \
        | jq '[.. | objects | to_entries[]
                | select(.key | test("api_key|token|(^|_)key$"; "i"))
                | select(.value != null and .value != false and .value != "")] | length' 2>/dev/null)
      [[ -n "$leaks" ]] || leaks="?"
      if [[ "$leaks" == "0" ]]; then
        ok "/api/config exposes no api_key/token/key values (sanitised)"
      else
        fail "/api/config exposes $leaks secret-looking value(s) — possible leak"
      fi
      if print -r -- "$REQ_BODY" | grep -qF -- "$API_KEY"; then
        fail "/api/config body contains the API key verbatim — leak"
      else
        ok "the API key does not appear anywhere in the /api/config body"
      fi
      ;;
    401) warn "/api/config needs key+token but none was accepted — skipping (try --pair)" ;;
    404) info "/api/config not present (server < 2.2.0) — skipping" ;;
    *)   warn "/api/config returned $REQ_CODE" ;;
  esac
}

check_devices() {
  section "paired devices"
  http_req GET /api/auth/devices
  case "$REQ_CODE" in
    200)
      local n now
      n=$(print -r -- "$REQ_BODY" | jq 'length')
      now=$(date +%s)
      ok "$n device token(s) enrolled"
      print -r -- "$REQ_BODY" \
        | jq -r '.[] | [(.label // "?"), ((.expires_at // "null")|tostring), ((.last_used // "never")|tostring)] | @tsv' \
        | while IFS=$'\t' read -r label exp last; do
            local expn="${exp%.*}"
            if [[ "$exp" == "null" ]]; then
              info "  $label — no expiry (last used $last)"
            elif [[ "$expn" == <-> ]]; then
              if (( expn < now )); then
                warn "  $label — token EXPIRED — revoke it: ac-approve … revoke <id>"
              elif (( expn < now + 604800 )); then
                warn "  $label — token expires within 7 days"
              else
                info "  $label — valid (last used $last)"
              fi
            else
              info "  $label — expires $exp (last used $last)"
            fi
          done
      ;;
    401|403) warn "/api/auth/devices needs the API key from the LAN — got $REQ_CODE (running off-LAN?)" ;;
    404) info "device-management endpoint not present" ;;
    *)   warn "/api/auth/devices returned $REQ_CODE" ;;
  esac
}

check_batch_state() {
  section "batch state"
  if ! has_feature batch_state; then info "server doesn't advertise batch_state — skipping"; return; fi
  http_req GET /api/units/state
  if [[ "$REQ_CODE" != "200" ]]; then fail "GET /api/units/state returned $REQ_CODE"; return; fi
  local n errs expected seen
  n=$(print -r -- "$REQ_BODY" | jq '(.states // []) | length')
  errs=$(print -r -- "$REQ_BODY" | jq '(.errors // []) | length')
  ok "batch returned $n state(s) in one request ($(ms_of $REQ_TIME) ms)"
  if [[ "$errs" != "0" ]]; then
    warn "batch reports $errs unreachable unit(s): $(print -r -- "$REQ_BODY" | jq -r '(.errors // [])[] | (.id // .unit_id // "?")' | tr '\n' ' ')"
  else
    ok "no per-unit errors in the batch response"
  fi
  expected=${#UNIT_IDS[@]}
  seen=$(( n + errs ))
  [[ "$seen" == "$expected" ]] && ok "batch covers all $expected configured unit(s)" \
    || warn "batch covered $seen unit(s); config has $expected"
}

check_bounds() {
  section "input validation"
  (( ${#UNIT_IDS[@]} > 0 )) || { info "no units to test against"; return; }
  http_req GET "/api/units/nonexistent-unit-id/state"
  [[ "$REQ_CODE" == "404" ]] && ok "unknown unit id correctly returns 404" \
    || warn "unknown unit id returned $REQ_CODE (expected 404)"
  local id="${UNIT_IDS[1]}"
  http_req POST "/api/units/$id/control" '{"target_temperature": 99}'
  case "$REQ_CODE" in
    422) ok "out-of-range target_temperature rejected with 422 (bounds enforced before touching the unit)" ;;
    400) ok "out-of-range target_temperature rejected with 400" ;;
    2[0-9][0-9]) fail "out-of-range target_temperature was ACCEPTED ($REQ_CODE) — server-side bounds not enforced" ;;
    *) warn "out-of-range control returned $REQ_CODE (expected 422)" ;;
  esac
}

check_programs() {
  section "programs / scheduler"
  if ! has_feature programs; then info "server doesn't advertise programs — skipping"; return; fi
  http_req GET /api/programs/status
  case "$REQ_CODE" in
    200) ok "scheduler status: $(print -r -- "$REQ_BODY" | jq -c '.' 2>/dev/null)" ;;
    401) warn "/api/programs/status needs key+token — skipping (no token)" ;;
    *)   warn "/api/programs/status returned $REQ_CODE" ;;
  esac
  http_req GET /api/programs
  if [[ "$REQ_CODE" == "200" ]]; then
    local total fav sch cur en
    total=$(print -r -- "$REQ_BODY" | jq 'length')
    fav=$(print -r -- "$REQ_BODY" | jq '[.[]|select(.kind=="favourite")]|length')
    sch=$(print -r -- "$REQ_BODY" | jq '[.[]|select(.kind=="schedule")]|length')
    cur=$(print -r -- "$REQ_BODY" | jq '[.[]|select(.kind=="curve")]|length')
    en=$(print -r -- "$REQ_BODY" | jq '[.[]|select(.enabled)]|length')
    ok "$total program(s): $fav favourite, $sch schedule, $cur curve ($en enabled)"
  fi
}

check_service() {
  # Host-local: is the breeze-core service running, and enabled at boot?
  # Only meaningful when run on the server itself — skips gracefully otherwise.
  section "background service"
  local -a names; names=(breeze-core meow-ac)
  local name found=""
  if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
    for name in $names; do
      systemctl list-unit-files "${name}.service" --no-legend 2>/dev/null | grep -q . || continue
      found=$name
      [[ "$(systemctl is-active "$name" 2>/dev/null)" == active ]] \
        && ok "service '$name' is running (systemd)" \
        || fail "service '$name' is installed but NOT running (systemd) — start it"
      [[ "$(systemctl is-enabled "$name" 2>/dev/null)" == enabled ]] \
        && ok "service '$name' is enabled to start at boot" \
        || warn "service '$name' is NOT enabled at boot — it won't return after a reboot"
      break
    done
  elif command -v rc-service >/dev/null 2>&1; then
    for name in $names; do
      [[ -e /etc/init.d/$name ]] || continue
      found=$name
      rc-service "$name" status >/dev/null 2>&1 \
        && ok "service '$name' is running (openrc)" \
        || fail "service '$name' is installed but NOT running (openrc) — start it"
      rc-update show 2>/dev/null | grep -qE "(^|[[:space:]])$name[[:space:]]" \
        && ok "service '$name' is enabled to start at boot" \
        || warn "service '$name' is NOT enabled at boot"
      break
    done
  elif command -v sv >/dev/null 2>&1 && [[ -d /etc/sv ]]; then
    for name in $names; do
      [[ -d /etc/sv/$name ]] || continue
      found=$name
      sv status "$name" 2>/dev/null | grep -q '^run:' \
        && ok "service '$name' is running (runit)" \
        || fail "service '$name' is NOT running (runit)"
      { [[ -L /var/service/$name || -L /etc/service/$name || -L /etc/runit/runsvdir/default/$name ]] } \
        && ok "service '$name' is enabled to start at boot" \
        || warn "service '$name' is NOT symlinked into the runsvdir (not boot-enabled)"
      break
    done
  else
    info "no recognised init/service manager here — skipping (run this on the server host)"
    return
  fi
  [[ -n "$found" ]] || info "no breeze-core/meow-ac service found here — skipping (run on the server host)"
}

check_connectivity() {
  section "connectivity"
  info "base url: $BASE_URL"
  http_req GET /api/health          # unauthenticated — clean reachability probe
  [[ "$REQ_CODE" == "000" ]] && http_req GET /api/units   # fall back for old builds
  if [[ "$REQ_CODE" == "000" ]]; then
    fail "could not reach $BASE_URL at all — is meow-ac running? (systemctl status meow-ac)"
    exit 1
  fi
  ok "server is reachable (http $REQ_CODE in $(ms_of $REQ_TIME) ms)"
}

check_auth() {
  section "authentication"

  local saved_key="$API_KEY" saved_tok="$DEVICE_TOKEN"

  API_KEY=""; DEVICE_TOKEN=""
  http_req GET /api/units
  [[ "$REQ_CODE" == "401" ]] && ok "request with no key correctly rejected (401)" \
    || fail "request with no key returned $REQ_CODE, expected 401"

  API_KEY="definitely-not-the-real-key"
  http_req GET /api/units
  [[ "$REQ_CODE" == "401" ]] && ok "request with wrong key correctly rejected (401)" \
    || fail "request with wrong key returned $REQ_CODE, expected 401"

  # Correct key, deliberately NO device token, to probe the auth posture.
  API_KEY="$saved_key"; DEVICE_TOKEN=""
  http_req GET /api/units
  case "$REQ_CODE" in
    200) ok "API key alone is accepted (200) — control API is not token-gated" ;;
    401) ok "API key alone is rejected (401) — a device token is also required (hardened; good)" ;;
    *)   warn "API key alone returned $REQ_CODE (expected 200 or 401)" ;;
  esac

  API_KEY="$saved_key"; DEVICE_TOKEN="$saved_tok"
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

# Resolve a --unit selector (exact id, or case-insensitive name) to a 1-based
# index. Prints the index and returns 0, or returns 1 if nothing matches.
find_unit_index() {
  local want="$1" i
  for i in {1..${#UNIT_IDS[@]}}; do
    [[ "${UNIT_IDS[$i]}" == "$want" ]] && { print -- "$i"; return 0; }
  done
  for i in {1..${#UNIT_IDS[@]}}; do
    [[ "${(L)UNIT_NAMES[$i]}" == "${(L)want}" ]] && { print -- "$i"; return 0; }
  done
  return 1
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
  local choice n
  local need="  (needs control-API access — use option 10 to pair a device token)"
  while true; do
    print ""
    print "meow-ac diagnostic — ${#UNIT_IDS[@]} unit(s), server ${SERVER_VERSION:-?} (${SERVER_COMMIT:-?})"
    print "  1) list configured units"
    print "  2) diagnose ONE unit"
    print "  3) diagnose ALL units"
    print "  4) connectivity + auth check"
    print "  5) server version & build"
    print "  6) security: config secret sanitisation"
    print "  7) paired devices"
    print "  8) batch state + input-validation checks"
    print "  9) programs / scheduler"
    print " 10) (re)pair this tool (mint a device token)"
    print " 11) forget the cached device token"
    print " 12) exit"
    print -n "choice: "
    read choice
    case "$choice" in
      1) print_unit_list ;;
      2)
        if [[ "$UNIT_AUTH_OK" != "1" ]]; then print "$need"; else
          print_unit_list
          print -n "unit number: "
          read n
          if [[ "$n" == <-> ]] && (( n >= 1 && n <= ${#UNIT_IDS[@]} )); then
            diagnose_unit "$n"; print_summary
          else
            print "not a valid unit number"
          fi
        fi
        ;;
      3) if [[ "$UNIT_AUTH_OK" == "1" ]]; then run_all_units; print_summary; else print "$need"; fi ;;
      4) check_connectivity; check_auth; print_summary ;;
      5) check_version ;;
      6) check_config_security ;;
      7) check_devices ;;
      8) if [[ "$UNIT_AUTH_OK" == "1" ]]; then check_units_listing; check_batch_state; check_bounds; print_summary; else print "$need"; fi ;;
      9) if [[ "$UNIT_AUTH_OK" == "1" ]]; then check_programs; else print "$need"; fi ;;
      10)
        if pair_device; then
          http_req GET /api/units
          if [[ "$REQ_CODE" == "200" ]]; then UNIT_AUTH_OK=1; ok "control API now reachable"; fi
        fi
        ;;
      11) forget_token; DEVICE_TOKEN="" ;;
      12) exit 0 ;;
      *) print "not a valid choice" ;;
    esac
  done
}

# ---------------------------------------------------------------------
# entry point
# ---------------------------------------------------------------------

# --forget-token is a standalone maintenance action.
[[ "$FORGET_TOKEN" == "1" ]] && { forget_token; exit 0; }

load_config
load_token_cache
check_service          # host-local: service running + enabled at boot
check_connectivity
check_version          # health + build + feature list (key-only)
check_auth
ensure_unit_auth       # get a device token if the control API needs one
check_devices          # paired tokens + expiry (key + LAN)

# The token-gated battery — run only when we actually have control-API access.
run_token_gated() {
  if [[ "$UNIT_AUTH_OK" != "1" ]]; then
    check_config_security   # reports its own skip
    section "token-gated checks"
    warn "skipped unit listing / batch / bounds / programs — no control-API access (see above)"
    return
  fi
  check_units_listing
  check_config_security
  check_batch_state
  check_bounds
  if [[ -n "$ONLY_UNIT" ]]; then
    local idx
    if idx=$(find_unit_index "$ONLY_UNIT"); then
      diagnose_unit "$idx"
    else
      fail "no unit matches --unit '$ONLY_UNIT' (give an id or an exact name)"
    fi
  else
    run_all_units
  fi
  check_programs
}

if [[ "$AUTO_MODE" == "1" || -n "$ONLY_UNIT" ]]; then
  run_token_gated
  print_summary
  (( TOTAL_FAIL == 0 ))
  exit $?
else
  interactive_menu
fi
