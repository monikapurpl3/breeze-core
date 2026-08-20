#!/usr/bin/env bash
# Smoke-test the built images the way someone would actually use them.
#
#   containers/test.sh                  # every image that exists locally
#   containers/test.sh ubi9-x86-64-v3   # just one
#   containers/test.sh --deep           # also disassemble, to prove -march took
#
# What each image is checked for: it starts, it says which image it is, it writes
# a first-run config at mode 640, it drops to the service account, the timezone
# database is really there, the panel answers 200, the API refuses a missing key
# and accepts the right one, and the CLI runs. The nginx image is checked over
# TLS instead of plain HTTP -- there the app deliberately listens on loopback
# only -- including a real enrolment and an SSE stream through the proxy, which
# is the part a proxy misconfiguration breaks silently.
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"; cd "$REPO"
LOCAL="${LOCAL_IMAGE:-breeze-core}"
PORT_BASE="${PORT_BASE:-18500}"
DEEP=0
FILTER=()
for a in "$@"; do
    case "$a" in
        --deep) DEEP=1 ;;
        -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
        *) FILTER+=("$a") ;;
    esac
done

# Git Bash rewrites any argument that looks like an absolute path into a Windows
# one, so `docker exec c /opt/breeze/...` becomes C:/Program Files/Git/opt/... and
# every in-container path fails with a baffling "no such file". Off.
export MSYS_NO_PATHCONV=1

fails=0
ok()   { printf '    ok    %s\n' "$*"; }
bad()  { printf '    FAIL  %s\n' "$*"; fails=$((fails + 1)); }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$2', got '$3')"; fi; }

cleanup() { docker rm -f bz-check >/dev/null 2>&1; docker volume rm -f bz-check-state >/dev/null 2>&1; }
trap cleanup EXIT

image_env() { docker exec bz-check sh -c ". /etc/breeze-image.env; printf '%s' \"\${$1:-}\""; }

wait_healthy() {
    local n=0
    while [ "$n" -lt "$1" ]; do
        case "$(docker inspect -f '{{.State.Health.Status}}' bz-check 2>/dev/null)" in
            healthy) return 0 ;;
            unhealthy) return 1 ;;
        esac
        # A container that died never becomes healthy OR unhealthy; without this
        # the loop just waits out the whole timeout and says nothing useful.
        [ "$(docker inspect -f '{{.State.Running}}' bz-check 2>/dev/null)" = false ] && return 1
        sleep 2; n=$((n + 2))
    done
    return 1
}

test_image() {  # test_image <tag> <host-port-app> <host-port-http-or-empty>
    local tag="$1" app_port="$2" http_port="${3:-}" plat="" base nginx=0
    case "$tag" in *aarch64*) plat="--platform linux/arm64" ;; esac
    case "$tag" in *nginx*)   nginx=1 ;; esac
    echo
    echo "==> $LOCAL:$tag"
    cleanup

    # In the nginx image the app binds 127.0.0.1 only and nginx is the way in, so
    # the published port is 8443 (TLS) plus 8080 for the redirect. Publishing
    # 8420 there would just be a port nothing listens on.
    local pubs
    if [ "$nginx" = 1 ]; then
        pubs="-p $app_port:8443 -p $http_port:8080"
        base="https://127.0.0.1:$app_port"
    else
        pubs="-p $app_port:8420"
        base="http://127.0.0.1:$app_port"
    fi

    # shellcheck disable=SC2086  # $plat and $pubs are intentionally word-split
    docker run -d --name bz-check $plat $pubs \
        -v bz-check-state:/etc/breeze-core \
        -e TZ=Europe/Zagreb -e BREEZE_SERVER_NAME=breeze.test \
        -e BREEZE_PUBLIC_HTTPS_PORT="$app_port" \
        "$LOCAL:$tag" >/dev/null || { bad "will not start"; return; }

    # arm64 runs under emulation here, which is slow to boot; give it longer.
    local budget=45
    case "$tag" in *aarch64*) budget=120 ;; esac
    if wait_healthy "$budget"; then ok "healthy within ${budget}s"
    else
        bad "never became healthy"
        docker logs bz-check 2>&1 | tail -12 | sed 's/^/          /'
        return
    fi

    # --- identity: the point of the labelling work ---
    check "banner names the image" "$tag" "$(image_env BREEZE_IMAGE)"
    [ -n "$(image_env BREEZE_BASE)" ] && ok "base recorded: $(image_env BREEZE_BASE)" \
                                      || bad "no BREEZE_BASE"
    local lbl
    lbl="$(docker image inspect "$LOCAL:$tag" -f '{{index .Config.Labels "org.opencontainers.image.title"}}')"
    [ -n "$lbl" ] && ok "OCI title: $lbl" || bad "no OCI title label"

    # --- the service account, not root ---
    # /proc/1/status, not ps: ubi-minimal ships no procps at all, so a ps-based
    # check reports an empty string and looks like a privilege bug.
    check "PID 1 runs as uid 1001" "1001" \
          "$(docker exec bz-check sh -c "awk '/^Uid:/{print \$2}' /proc/1/status")"

    check "config mode" "640" \
          "$(docker exec bz-check stat -c '%a' /etc/breeze-core/config.json)"

    # --- tzdata: without it TZ is silently ignored and schedules fire on UTC ---
    local tzn
    tzn="$(docker exec bz-check /opt/breeze/venv/bin/python3 -c 'import time; print(time.tzname[0])')"
    if [ "$tzn" = "CET" ]; then ok "timezone database present (tzname CET)"
    else bad "TZ=Europe/Zagreb resolved to '$tzn' -- tzdata missing, schedules would run on UTC"; fi

    # --- it actually serves (-k throughout: the nginx image is self-signed) ---
    check "panel answers" "200" \
          "$(curl -sS -k -o /dev/null -w '%{http_code}' --max-time 15 "$base/" 2>/dev/null)"
    local key
    key="$(docker exec bz-check sh -c 'grep -o "\"api_key\": \"[^\"]*\"" /etc/breeze-core/config.json | cut -d\" -f4')"
    if curl -sS -k --max-time 15 -H "X-API-Key: $key" "$base/api/version" 2>/dev/null \
         | grep -q '"name":"Breeze Core"'; then ok "/api/version with the key"
    else bad "/api/version did not answer with the key"; fi
    check "/api/version without a key" "401" \
          "$(curl -sS -k -o /dev/null -w '%{http_code}' --max-time 15 "$base/api/version" 2>/dev/null)"

    docker exec bz-check breeze-core version >/dev/null 2>&1 \
        && ok "breeze-core CLI runs" || bad "breeze-core CLI does not run"

    # Captured, not piped: breeze-setup exits 1 on purpose without a tty, and
    # under `set -o pipefail` that non-zero status wins over grep's success --
    # so a piped check fails on the very behaviour it is trying to confirm.
    local setup_out
    setup_out="$(docker exec bz-check breeze-setup 2>&1 || true)"
    case "$setup_out" in
      *"needs a terminal"*) ok "breeze-setup refuses a non-tty with an explanation" ;;
      *) bad "breeze-setup said something unexpected without a tty: ${setup_out%%$'\n'*}" ;;
    esac

    # --- per-family extras ---
    case "$tag" in
      alpine*)
        local world
        world="$(docker exec bz-check grep '^python3' /etc/apk/world)"
        case "$world" in
          python3~*) ok "python pinned to its minor series ($world)" ;;
          *) bad "python is NOT pinned ($world) -- an apk upgrade could break the venv" ;;
        esac
        docker logs bz-check 2>&1 | grep -q 'edge self-update' \
            && ok "edge self-update ran at start" || bad "no edge self-update line"
        ;;
      ubi9*)
        local flags
        flags="$(image_env BREEZE_REQUIRED_CPU_FLAGS)"
        [ -n "$flags" ] && ok "declares the CPU flags it needs ($flags)" \
                        || bad "no BREEZE_REQUIRED_CPU_FLAGS -- a v3 image would SIGILL unexplained"
        ;;
    esac

    if [ "$nginx" = 1 ]; then
        docker logs bz-check 2>&1 | grep -qiE 'alert|emerg|denied' \
            && bad "nginx complained on startup" || ok "nginx started clean"
        local loc
        loc="$(curl -sSi --max-time 15 "http://127.0.0.1:$http_port/" 2>/dev/null \
               | awk 'tolower($1)=="location:"{print $2}' | tr -d '\r')"
        case "$loc" in
          https://*) ok "plain HTTP redirects to $loc" ;;
          *) bad "no HTTPS redirect from the plain listener (got '$loc')" ;;
        esac
        test_sse_through_proxy "$base" "$key"
    fi
}

# The proxy check that matters: enrol for real, then stream. A missing
# proxy_buffering off does not error -- it just holds events until a buffer
# fills, so the live view looks frozen and nothing in any log says why.
test_sse_through_proxy() {
    local base="$1" key="$2" start code sess tok first
    start="$(curl -sS -k --max-time 15 -X POST "$base/api/auth/enroll/start" \
             -H "X-API-Key: $key" -H 'Content-Type: application/json' -d '{"label":"container-test"}')"
    code="$(printf '%s' "$start" | sed -n 's/.*"user_code":"\([^"]*\)".*/\1/p')"
    sess="$(printf '%s' "$start" | sed -n 's/.*"session_id":"\([^"]*\)".*/\1/p')"
    [ -n "$code" ] || { bad "enrolment did not start through the proxy"; return; }
    docker exec bz-check breeze-core approve "$code" --base-url http://127.0.0.1:8420 >/dev/null 2>&1 \
        || { bad "approval failed (does the LAN-only check see the right client address?)"; return; }
    tok="$(curl -sS -k --max-time 15 -X POST "$base/api/auth/enroll/poll" \
           -H "X-API-Key: $key" -H 'Content-Type: application/json' -d "{\"session_id\":\"$sess\"}" \
           | sed -n 's/.*"device_token":"\([^"]*\)".*/\1/p')"
    [ -n "$tok" ] || { bad "no device token after approval"; return; }
    ok "enrol -> approve -> token, all through nginx"

    # The stream opens with a ': connected' comment. Through a buffering proxy it
    # would not arrive at all inside this window.
    first="$(curl -sS -k -N --max-time 6 -H "X-API-Key: $key" -H "Authorization: Bearer $tok" \
             -H 'Accept: text/event-stream' "$base/api/units/stream" 2>/dev/null | head -1)"
    case "$first" in
      *connected*) ok "SSE arrives immediately through the proxy" ;;
      *) bad "no prompt SSE preamble through nginx (got '$first') -- buffering?" ;;
    esac
}

# ---------------------------------------------------------------- deep check
# Proof, rather than assertion, that ARCH_LEVEL reached the compiler: pull one
# compiled extension out of each UBI image and disassemble it.
#
# The naive version of this check ("v2 must contain no AVX2 at all") FAILS, and
# usefully so: the v2 build really does contain ~700 AVX2 instructions. They are
# not a compiler-flag leak, they are runtime-dispatched code inside dependencies
# -- memchr and friends compile several implementations and pick one after
# asking CPUID, which is why the same object also contains cpuid instructions.
# Perfectly safe on a CPU without AVX2, because that path is never entered.
#
# What actually distinguishes the images is the ORDER OF MAGNITUDE: ~700 in v2
# against ~38,000 in v3. If -march had silently not applied, both would sit at
# the baseline-plus-dispatch figure. So: v3 must be far higher, v2 must stay near
# the dispatch-only floor, and v2 must show CPUID checks.
#
# binutils is deliberately absent from the runtime images, so the object is
# copied out and fed to a throwaway container over stdin -- no bind mount, which
# is unreliable on this workstation.
deep_check() {
    local tmp so n v2_avx=0
    # A path relative to the repo, not mktemp -d. MSYS_NO_PATHCONV is on for the
    # sake of the in-container paths, which means `docker cp`'s HOST argument is
    # handed to a Windows docker client verbatim: /tmp/tmp.XYZ then resolves to
    # C:\tmp\tmp.XYZ, which does not exist, and the copy fails with nothing but
    # "could not extract".
    tmp=".bz-deep-$$"
    mkdir -p "$tmp"
    for tag in ubi9-x86-64-v2 ubi9-x86-64-v3; do
        docker image inspect "$LOCAL:$tag" >/dev/null 2>&1 || continue
        so="$(docker run --rm --entrypoint sh "$LOCAL:$tag" -c \
              'ls /opt/breeze/venv/lib/python3.12/site-packages/pydantic_core/*.so 2>/dev/null | head -1')"
        [ -n "$so" ] || { bad "$tag: no pydantic_core .so to inspect"; continue; }
        docker rm -f bz-extract >/dev/null 2>&1
        docker create --name bz-extract "$LOCAL:$tag" >/dev/null
        docker cp "bz-extract:$so" "$tmp/$tag.so" >/dev/null 2>&1
        docker rm -f bz-extract >/dev/null 2>&1
        [ -s "$tmp/$tag.so" ] || { bad "could not extract $so from $tag"; continue; }
        # Two numbers in one pass: AVX2 instructions, and cpuid (the evidence of
        # runtime dispatch).
        n="$(tar -cf - -C "$tmp" "$tag.so" | docker run --rm -i alpine:3.20 sh -c \
             'apk add -q binutils >/dev/null 2>&1; tar -xf - -C /tmp;
              d="$(objdump -d /tmp/*.so 2>/dev/null)";
              printf "%s %s" "$(printf "%s" "$d" | grep -cE "ymm[0-9]|vfmadd")" \
                             "$(printf "%s" "$d" | grep -cw cpuid)"')"
        local avx cpuid
        avx="${n%% *}"; cpuid="${n##* }"
        avx="${avx//[!0-9]/}"; cpuid="${cpuid//[!0-9]/}"
        avx="${avx:-0}"; cpuid="${cpuid:-0}"
        case "$tag" in
          *v2) v2_avx="$avx"
               if [ "$cpuid" -gt 0 ]; then
                   ok "v2 sits at the dispatch floor: $avx AVX2 instructions, behind $cpuid cpuid checks"
               else
                   bad "v2 has $avx AVX2 instructions and NO cpuid checks -- that would SIGILL pre-Haswell"
               fi ;;
          *v3) if [ "$avx" -gt $(( ${v2_avx:-0} * 10 )) ]; then
                   ok "v3 is compiled for AVX2 throughout: $avx instructions vs v2's ${v2_avx:-?}"
               else
                   bad "v3 has only $avx AVX2 instructions against v2's ${v2_avx:-?} -- -march never reached the compiler"
               fi ;;
        esac
    done
    rm -rf "$tmp"
}

echo "Breeze Core container checks"
i=0
for tag in ubi9-x86-64-v2 ubi9-x86-64-v3 alpine-edge-x86_64 alpine-edge-aarch64 alpine-edge-nginx-x86_64; do
    if [ ${#FILTER[@]} -gt 0 ]; then
        keep=0; for f in "${FILTER[@]}"; do [ "$f" = "$tag" ] && keep=1; done
        [ "$keep" = 1 ] || continue
    fi
    docker image inspect "$LOCAL:$tag" >/dev/null 2>&1 || { echo; echo "==> $tag (not built -- skipped)"; continue; }
    test_image "$tag" "$((PORT_BASE + i))" "$((PORT_BASE + i + 50))"
    i=$((i + 1))
done

if [ "$DEEP" = 1 ]; then
    echo
    echo "==> deep: does ARCH_LEVEL actually reach the compiler?"
    deep_check
fi

echo
if [ "$fails" = 0 ]; then echo "all checks passed"; else echo "$fails check(s) failed"; fi
exit $((fails > 0))
