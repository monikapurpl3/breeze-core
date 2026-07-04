#!/usr/bin/env zsh
#
# ac-approve.zsh — the admin's companion tool for the meow-ac pairing flow.
#
# When someone opens the web UI on a new device, it shows a short pairing
# code. You (the admin), on the LAN, relay that code here to approve it;
# the device then receives its per-device token and can control the units.
#
# Because approval and device management are restricted to the local
# network, run this ON meow (or another LAN host), pointed at the LAN URL.
# It reads /etc/meow-ac/config.json for the API key, exactly like
# ac-diag.zsh, so you never type the key in by hand.
#
# Usage:
#   ac-approve.zsh --base-url http://192.168.1.10:8420 approve K7Q2-9MRX
#   ac-approve.zsh --base-url http://192.168.1.10:8420 list
#   ac-approve.zsh --base-url http://192.168.1.10:8420 revoke 3f9a1c...
#   ac-approve.zsh --base-url http://192.168.1.10:8420        # prompts for a code
#
# Needs: curl, jq. Read access to config.json (mode 600) — run with sudo
# or join the meow-ac group.

emulate -L zsh
setopt err_return no_unset pipe_fail

CONFIG_PATH="${AC_CONFIG:-/etc/meow-ac/config.json}"
BASE_URL=""
API_KEY=""

die() { print "error: $1" >&2; exit 1 }

usage() {
  cat <<'EOF'
ac-approve.zsh — approve/manage meow-ac device pairings (admin, LAN-only)

  --config PATH        path to config.json (default: /etc/meow-ac/config.json
                        or $AC_CONFIG)
  --base-url URL       API base URL (default: http://127.0.0.1:8420)

  approve CODE         approve a pairing code shown on a device
  list                 list enrolled devices
  revoke TOKEN_ID      revoke a device by its token_id
  (no command)         prompt for a code to approve
EOF
}

# --- args ---
local -a positional
positional=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --config) CONFIG_PATH="$2"; shift 2 ;;
    --base-url) BASE_URL="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) positional+=("$1"); shift ;;
  esac
done
BASE_URL="${BASE_URL:-http://127.0.0.1:8420}"

for bin in curl jq; do
  command -v "$bin" >/dev/null 2>&1 || die "$bin is required. Install with: sudo dnf install $bin"
done

[[ -r "$CONFIG_PATH" ]] || die "can't read $CONFIG_PATH — run with sudo, or join the meow-ac group"
jq empty "$CONFIG_PATH" >/dev/null 2>&1 || die "$CONFIG_PATH is not valid JSON"
API_KEY=$(jq -r '.api_key // empty' "$CONFIG_PATH")
[[ -n "$API_KEY" ]] || die "no api_key in $CONFIG_PATH"

# HTTP helper — note: the local is NOT named "path" (zsh ties $path to
# $PATH; see ac-diag.zsh for the war story). Sets REQ_BODY / REQ_CODE.
REQ_BODY="" REQ_CODE=""
http_req() {
  local method="$1" endpoint="$2" data="${3:-}"
  local raw
  if [[ -n "$data" ]]; then
    raw=$(curl -s -w $'\nHTTPSTATUS:%{http_code}' -X "$method" \
      -H "X-API-Key: $API_KEY" -H "Content-Type: application/json" \
      -d "$data" "$BASE_URL$endpoint" 2>/dev/null) || true
  else
    raw=$(curl -s -w $'\nHTTPSTATUS:%{http_code}' -X "$method" \
      -H "X-API-Key: $API_KEY" "$BASE_URL$endpoint" 2>/dev/null) || true
  fi
  REQ_CODE=$(print -r -- "$raw" | grep '^HTTPSTATUS:' | cut -d: -f2)
  REQ_BODY=$(print -r -- "$raw" | grep -v '^HTTPSTATUS:')
  [[ -n "$REQ_CODE" ]] || REQ_CODE="000"
}

do_approve() {
  local code="$1"
  [[ -n "$code" ]] || die "no code given"
  http_req POST /api/auth/enroll/approve "{\"code\": \"$code\"}"
  case "$REQ_CODE" in
    200)
      local label id
      label=$(print -r -- "$REQ_BODY" | jq -r '.label')
      id=$(print -r -- "$REQ_BODY" | jq -r '.token_id')
      print "approved: \"$label\" (token_id $id). The device now has its token." ;;
    400) print "rejected: invalid or expired code (they expire fast — get a fresh one)" ;;
    403) print "rejected: this host isn't on the trusted LAN (approval is LAN-only)" ;;
    401) die "the API key in $CONFIG_PATH was rejected (401)" ;;
    000) die "couldn't reach $BASE_URL — is meow-ac running, and is the URL right?" ;;
    *)   die "unexpected response ($REQ_CODE): $REQ_BODY" ;;
  esac
}

do_list() {
  http_req GET /api/auth/devices
  [[ "$REQ_CODE" == "200" ]] || die "list failed ($REQ_CODE): $REQ_BODY"
  local n
  n=$(print -r -- "$REQ_BODY" | jq 'length')
  if [[ "$n" == "0" ]]; then print "no devices enrolled yet."; return; fi
  print "enrolled devices ($n):"
  print -r -- "$REQ_BODY" | jq -r '.[] |
    "  \(.token_id)  \(.label)  (enrolled \(.created_at | strftime("%Y-%m-%d %H:%M")))" +
    (if .last_used then "  last used \(.last_used | strftime("%Y-%m-%d %H:%M"))" else "  never used" end)'
}

do_revoke() {
  local id="$1"
  [[ -n "$id" ]] || die "no token_id given"
  http_req DELETE "/api/auth/devices/$id"
  case "$REQ_CODE" in
    204) print "revoked $id — that device can no longer control the units." ;;
    404) print "no device with token_id $id (try: list)" ;;
    403) die "this host isn't on the trusted LAN (management is LAN-only)" ;;
    401) die "the API key was rejected (401)" ;;
    *)   die "unexpected response ($REQ_CODE): $REQ_BODY" ;;
  esac
}

case "${positional[1]:-}" in
  approve) do_approve "${positional[2]:-}" ;;
  list)    do_list ;;
  revoke)  do_revoke "${positional[2]:-}" ;;
  "")
    print -n "pairing code to approve: "
    local code; read code
    do_approve "$code"
    ;;
  *) print "unknown command: ${positional[1]}"; usage; exit 1 ;;
esac
