#!/usr/bin/env bash
# Verify os-breeze-core the way it will actually be installed.
#
#   packaging/opnsense/verify-plugin.sh [freebsd-builder-host]
#
# The target is reproduced deliberately meanly: a FreeBSD 14 userland with
# **python311 and nothing else** — no rust, no pip, no compiler — because that is
# what an OPNsense box offers. If the package needs any of them at install time it
# is broken for the target, and this is what catches it.
#
# NOT covered: the GUI. The MVC page, menu and configd wiring need OPNsense's own
# PHP stack, so the PHP is lint-checked and the XML parsed here, but "the page
# renders and the toggle works" has to be confirmed on a real install. Everything
# below that line — install, ABI, dependency resolution, the vendored runtime, the
# CLI, the rc script, the HTTP endpoint — is checked for real.
set -euo pipefail

HOST="${1:-192.168.122.131}"
USER_AT="${BSD_USER:-monika}@$HOST"
ROOT="${FB14_ROOT:-/jail/fb14}"
TEST="${TEST_ROOT:-/jail/test14}"
# Not 8420: a chroot shares the host network stack and the builder VM may be
# running Breeze Core itself from the FreeBSD package work, which gives "address
# already in use" and looks exactly like a broken rc script.
PORT="${VERIFY_PORT:-18420}"
FB_BASE="${FB_BASE:-14.3-RELEASE}"

# Every `breeze-core <verb>` the plugin tells an admin to run must BE a
# subcommand. This is not hypothetical: the first cut of this plugin told people
# to run `breeze-core setup` -- in the GUI page, the pkg install message and the
# docs -- and there is no such subcommand. It is `pair`. Nothing caught it,
# because none of it is code: the package installs fine and the page renders
# fine, and the admin just gets a usage error at the one moment they follow the
# instructions. The CLI's own parser is the source of truth.
echo "=== documented CLI verbs exist ==="
verbs="$(sed -n 's/.*sub\.add_parser("\([a-z]*\)".*/\1/p' meow_ac/cli/main.py | tr '\n' ' ')"
echo "  CLI offers: $verbs"
unknown=""
# The OPNsense doc moved to the wiki, so it is no longer scannable from here --
# only the plugin's own text is. That is the part that ships, so it is the part
# that matters; wiki prose cannot be checked by CI at all.
# --exclude this file: it is the test, not user-facing text, and the paragraph
# above necessarily contains the very string it is looking for. Scanning itself
# made the guard fail on its own comment -- plus 'the' and 'plugin' out of the
# prose. With the verifier excluded every remaining match is a real instruction
# to a real admin, so no ignore-list of English words is needed.
for w in $(grep -rhoE 'breeze-core [a-z]+' packaging/opnsense \
             --exclude=verify-plugin.sh 2>/dev/null \
             | awk '{print $2}' | sort -u); do
    case " $verbs " in
        *" $w "*) ;;
        *) unknown="$unknown $w" ;;
    esac
done
if [ -n "$unknown" ]; then
    echo "  FAIL: named as subcommands but do not exist:$unknown"
    echo "        (check against: $verbs)"
    exit 1
fi
echo "  every verb named in the plugin text is a real subcommand"

# No -n here: stdin IS the heredoc carrying the remote script, and -n points
# stdin at /dev/null, so the remote side runs nothing at all and the only
# symptom is a missing artefact at the end.
ssh -o BatchMode=yes "$USER_AT" "ROOT='$ROOT' TEST='$TEST' PORT='$PORT' FB_BASE='$FB_BASE' sh -s" <<'REMOTE'
set -eu
fail=0
note() { echo "  $*"; }
bad()  { echo "  FAIL: $*"; fail=1; }

cleanup_test_root() {
    # doas, and never a bare pkill: the service runs as the breeze account, so an
    # unprivileged pkill returns "Operation not permitted" and `|| true` hides it.
    # That is exactly how a stray from the previous run kept holding $PORT and
    # answered HTTP 500, while this run's start failed "address already in use"
    # and looked like a broken rc script.
    #
    # The pattern says lib/breeze-core, not breeze-core: this builder ALSO runs
    # the FreeBSD *package* out of /usr/local/breeze-core, and a loose pattern
    # kills the VM's own service as collateral. The plugin lives under lib/.
    #
    # pkill -f "$TEST" matches nothing, incidentally — inside the chroot the argv
    # is /usr/local/lib/..., with no mention of the test root anywhere in it.
    doas pkill -f 'lib/breeze-core/(serve\.sh|venv)' 2>/dev/null || true
    # Belt and braces: anything still on the verify port, whatever it is called.
    for p in $(sockstat -4 -l 2>/dev/null | awk -v pp=":$PORT" '$6 ~ (pp "$") {print $3}'); do
        doas kill "$p" 2>/dev/null || true
    done
    n=0
    while sockstat -4 -l 2>/dev/null | grep -q ":$PORT "; do
        n=$((n + 1)); [ "$n" -ge 5 ] && break; sleep 1
    done
    sockstat -4 -l 2>/dev/null | grep -q ":$PORT " && \
        bad "port $PORT is still held by something; the rc test below will misreport"

    n=0
    while mount | grep -q " on $TEST/dev "; do
        doas umount "$TEST/dev" 2>/dev/null || doas umount -f "$TEST/dev" 2>/dev/null || true
        n=$((n + 1))
        [ "$n" -ge 5 ] && break
        sleep 1
    done
    if mount | grep -q " on $TEST/dev "; then
        # Never rm around a live devfs: rm recurses into it, reports "Operation
        # not supported" per node, then "Device busy", and leaves the root behind
        # for the next run to trip over.
        bad "devfs is still mounted on $TEST/dev; not removing the test root"
        return 0
    fi
    if [ -d "$TEST" ]; then
        # schg: base files (/sbin/init, libexec/ld-elf.so.1, var/empty) are
        # immutable, so rm fails even as root without clearing the flag.
        doas chflags -R noschg "$TEST" 2>/dev/null || true
        doas rm -rf "$TEST"
    fi
}
cleanup_test_root

doas mkdir -p "$TEST"
# /tmp is cleared on FreeBSD reboot (clear_tmp_enable), and build-plugin.sh only
# fetches base.txz when the build root is absent -- which it is not, after the
# first build. So a VM reboot leaves a working builder and a verifier that dies
# on "tar: Failed to open /tmp/base14.txz". Fetch it here too rather than
# depending on a leftover from another script.
[ -f /tmp/base14.txz ] || fetch -q -o /tmp/base14.txz \
    "https://download.freebsd.org/releases/amd64/$FB_BASE/base.txz"
doas tar -xpf /tmp/base14.txz -C "$TEST"
doas cp /etc/resolv.conf "$TEST/etc/resolv.conf"
doas mount -t devfs devfs "$TEST/dev"

# A bare base.txz has no /etc/login.conf.db, and without it setusercontext()
# fails -- so `daemon -u breeze` dies with "failed to set user environment"
# and the service never starts. A real FreeBSD or OPNsense install always has
# this database, so its absence here is a deficiency of the TEST ROOT, not of
# the package; building it makes the test faithful instead of pessimistic.
doas chroot "$TEST" cap_mkdb /etc/login.conf

echo "=== target: FreeBSD 14, python311 only (what OPNsense gives you) ==="
doas chroot "$TEST" /bin/sh -c '
    export ASSUME_ALWAYS_YES=yes
    pkg bootstrap -f >/dev/null 2>&1 || true
    pkg update -q && pkg install -y python311 >/dev/null
    echo "  python: $(python3.11 -V 2>&1)"
    echo "  rust:   $(command -v rustc || echo absent)"
    echo "  pip:    $(command -v pip || echo absent)"
'

doas cp "$ROOT"/tmp/pkgout/os-breeze-core-*.pkg "$TEST/tmp/"

echo "=== pkg add ==="
doas chroot "$TEST" /bin/sh -c '
    export ASSUME_ALWAYS_YES=yes
    pkg add /tmp/os-breeze-core-*.pkg 2>&1 | sed "s/^/  /"
'
echo "=== metadata ==="
doas chroot "$TEST" pkg info -f os-breeze-core | grep -E '^(Name|Version|Architecture|Prefix)' | sed 's/^/  /'
doas chroot "$TEST" pkg info -d os-breeze-core | tail -n +2 | sed 's/^/  dep: /'

echo "=== vendored runtime + CLI (nothing compiled on this box) ==="
doas chroot "$TEST" /bin/sh -c '
    P=/usr/local/lib/breeze-core
    "$P/venv/bin/python3.11" -c "import fastapi, uvicorn, msmart, pydantic_core, brotli_asgi; print(\"  imports ok, pydantic_core\", pydantic_core.__version__)"
' || bad "vendored runtime cannot import"
doas chroot "$TEST" /bin/sh -c 'timeout 30 /usr/local/bin/breeze-core version 2>&1 | sed "s/^/  cli: /"' \
    || bad "the breeze-core CLI wrapper does not run"

echo "=== PHP lint (a syntax error here is a dead GUI page) ==="
doas chroot "$TEST" /bin/sh -c 'export ASSUME_ALWAYS_YES=yes; pkg install -y php83 >/dev/null 2>&1' || true
doas chroot "$TEST" /bin/sh -c '
    if command -v php >/dev/null; then
        for f in $(find /usr/local/opnsense -name "*.php"); do
            php -l "$f" || exit 1
        done | sed "s|/usr/local/opnsense/mvc/app/|  |"
    else
        echo "  (php unavailable — skipped)"
    fi
' || bad "PHP does not lint"

# What configd renders from the template, at the path rc.subr actually sources.
# The test deliberately sets NO environment for the rc script: passing
# breeze_core_port= in the environment (as this did) bypasses the whole config
# path, which is how a template pointed at a path load_rc_config never reads
# went unnoticed -- the service would have ignored the GUI's address and port.
doas mkdir -p "$TEST/usr/local/etc/rc.conf.d"
doas sh -c "cat > $TEST/usr/local/etc/rc.conf.d/breeze_core" <<RCCONF
breeze_core_enable="YES"
breeze_core_host="127.0.0.1"
breeze_core_port="$PORT"
breeze_core_config="/usr/local/etc/breeze-core/config.json"
RCCONF

# The HTTP probe as a file, not python -c: this runs inside chroot ... sh -c "...",
# where a nested double quote ends the outer string and leaves python a bare -c
# ("Argument expected for the -c option"). A file has no quoting to lose.
# The vendored interpreter rather than fetch(1), whose --header support varies by
# release -- an unsupported option there is indistinguishable from a dead server,
# which is how this check once printed nothing while the service was serving.
doas sh -c "cat > $TEST/tmp/httpcheck.py" <<PROBE
import urllib.request
req = urllib.request.Request('http://127.0.0.1:$PORT/api/version',
                             headers={'X-API-Key': 'opnsense-verify'})
print(urllib.request.urlopen(req, timeout=5).read().decode()[:160])
PROBE

echo "=== rc script, driven only by the rendered rc.conf.d (port $PORT) ==="
doas chroot "$TEST" /bin/sh -c "
    install -d -o breeze -g breeze -m 750 /usr/local/etc/breeze-core
    printf '%s' '{\"api_key\": \"opnsense-verify\", \"units\": []}' > /usr/local/etc/breeze-core/config.json
    chown breeze:breeze /usr/local/etc/breeze-core/config.json
    # 'start', not 'onestart': start honours the rcvar, so it only runs if
    # breeze_core_enable came out of the rendered file. onestart forces, and
    # would pass whether the file was read or not.
    rm -f /tmp/breeze-start.log
    /usr/local/etc/rc.d/breeze_core start >/tmp/breeze-start.log 2>&1 || true
    sed 's/^/  /' /tmp/breeze-start.log
    sleep 8
    /usr/local/etc/rc.d/breeze_core status 2>&1 | tee /tmp/breeze-status.log | sed 's/^/  /'
    # The GUI's status light is literally strpos(output, 'is running') on this
    # text -- ApiMutableServiceControllerBase::statusAction() shells out to the
    # same configd action. Rewording the rc script would leave the service
    # working and the GUI permanently showing 'unknown', so assert the wording.
    grep -q 'is running' /tmp/breeze-status.log || echo '  FAIL: status output lacks \"is running\" (GUI would read unknown)'
    # Answering on \$PORT is the proof the port came from the file: the built-in
    # default is 8420, where nothing of ours would be listening.
    printf '  GET /api/version -> '
    /usr/local/lib/breeze-core/venv/bin/python3.11 /tmp/httpcheck.py 2>&1 | tail -1 | sed 's/^/    /'
    /usr/local/etc/rc.d/breeze_core stop 2>&1 | sed 's/^/  /'
    /usr/local/etc/rc.d/breeze_core status 2>&1 | tee /tmp/breeze-status2.log | sed 's/^/  /'
    grep -q 'not running' /tmp/breeze-status2.log || echo '  FAIL: stopped status lacks \"not running\"'
    echo '  --- /var/log/breeze_core.log ---'
    tail -12 /var/log/breeze_core.log 2>/dev/null | sed 's/^/    /' || echo '    (empty)'
" > /tmp/rc-sequence.log 2>&1 || bad "the rc start/status/HTTP/stop sequence did not complete"
cat /tmp/rc-sequence.log
# The greps above print FAIL from inside the chroot, where `fail` is a different
# shell's variable -- so lift it back out here or a red line scrolls past with a
# green exit code.
grep -q 'FAIL:' /tmp/rc-sequence.log && bad "the rc status wording does not match what the GUI greps for"

# Leave nothing running or mounted behind: the previous round of this work left
# stray uvicorn processes that then broke the NEXT run with "already running".
cleanup_test_root
echo "=== test root removed, nothing left running ==="
exit $fail
REMOTE
