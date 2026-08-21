#!/usr/bin/env bash
# Build the os-breeze-core OPNsense plugin package.
#
#   packaging/opnsense/build-plugin.sh [freebsd-builder-host]
#
# Output: packaging/out/opnsense/os-breeze-core-<ver>.pkg
#
# Why this needs its own build rather than reusing the FreeBSD package, and every
# trap encountered getting here, are written up in https://github.com/monikapurpl3/breeze-core/wiki/Installing-on-OPNsense. The short
# version: OPNsense is FreeBSD:14 with python311 and no rust, no pip, and none of
# our dependencies — so the whole runtime is vendored and built in a FreeBSD 14
# userland on the builder VM.
set -euo pipefail

HOST="${1:-192.168.122.131}"
USER_AT="${BSD_USER:-monika}@$HOST"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"; cd "$REPO"
VER="$(sed -n 's/^__version__ = "\(.*\)"/\1/p' meow_ac/__init__.py)"
# The build stamp /api/version and `breeze-core version` report. It has to be
# passed in and written explicitly: this build tars the WORKING TREE, and
# meow_ac/_commit.txt is gitignored -- so whatever stale copy a developer
# happened to have locally got packaged and reported as the running build. An
# OPNsense install claimed commit 987911d for weeks because of exactly that.
SHA="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
ROOT="${FB14_ROOT:-/jail/fb14}"
FB_BASE="${FB_BASE:-14.3-RELEASE}"
OUT=packaging/out/opnsense
mkdir -p "$OUT"

echo "==> os-breeze-core $VER  (builder $USER_AT, $ROOT, FreeBSD $FB_BASE)" >&2

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
# An ALLOWLIST, not `tar . --exclude=...`. The remote side reads exactly three
# things out of this archive -- meow_ac/, static/ and packaging/opnsense/files/
# -- and the denylist version this replaces shipped the whole working tree to
# the build VM, signing keys included. src_tar_allow also refuses to hand over
# an archive containing key material. See packaging/lib/src-tar.sh.
. packaging/lib/src-tar.sh
src_tar_allow "$TMP/src.tar.gz" meow_ac static packaging/opnsense/files
scp -q -o BatchMode=yes "$TMP/src.tar.gz" "$USER_AT:/tmp/bc-opn-src.tar.gz"

# No -n here: stdin IS the heredoc carrying the remote script, and -n points
# stdin at /dev/null, so the remote side runs nothing at all and the only
# symptom is a missing artefact at the end.
ssh -o BatchMode=yes "$USER_AT" "VER='$VER' SHA='$SHA' ROOT='$ROOT' FB_BASE='$FB_BASE' sh -s" <<'REMOTE'
set -eu

# ---------------------------------------------------------- 1. FreeBSD 14 root
if [ ! -x "$ROOT/usr/local/bin/python3.11" ]; then
    echo "  creating the FreeBSD 14 build root"
    doas mkdir -p "$ROOT"
    [ -f /tmp/base14.txz ] || \
        fetch -q -o /tmp/base14.txz "https://download.freebsd.org/releases/amd64/$FB_BASE/base.txz"
    doas tar -xpf /tmp/base14.txz -C "$ROOT"
    doas cp /etc/resolv.conf "$ROOT/etc/resolv.conf"
fi

# devfs is NOT optional. Without it cargo pipes source to `rustc -` on stdin,
# that read misbehaves with no /dev, and rustc parses an error message as source:
# "E0554: #![feature] may not be used on the stable release channel" — which
# looks like a toolchain problem and is not one.
mount | grep -q "$ROOT/dev" || doas mount -t devfs devfs "$ROOT/dev"

doas chroot "$ROOT" /bin/sh -c '
    export ASSUME_ALWAYS_YES=yes
    pkg bootstrap -f >/dev/null 2>&1 || true
    pkg update -q
    pkg install -y python311 rust >/dev/null
'
echo "  build root: $(doas chroot "$ROOT" pkg config ABI), $(doas chroot "$ROOT" python3.11 -V 2>&1)"

# ------------------------------------------------------ 2. vendored runtime
doas rm -rf "$ROOT/tmp/src"; doas mkdir -p "$ROOT/tmp/src"
doas tar -xzf /tmp/bc-opn-src.tar.gz -C "$ROOT/tmp/src"

# Built at its FINAL path: a venv bakes absolute paths into pyvenv.cfg and every
# console script, so building elsewhere and relocating only appears to work.
doas chroot "$ROOT" /bin/sh -c '
    set -eu
    P=/usr/local/lib/breeze-core
    if [ ! -x "$P/venv/bin/python3.11" ]; then
        echo "  building the venv (pydantic-core compiles HERE, never on the firewall)"
        rm -rf "$P"; mkdir -p "$P"
        python3.11 -m venv "$P/venv"
        "$P/venv/bin/pip" -q install --upgrade pip wheel
        "$P/venv/bin/pip" -q install fastapi uvicorn msmart-ng brotli-asgi
    fi
    rm -rf "$P/meow_ac" "$P/static"
    cp -R /tmp/src/meow_ac /tmp/src/static "$P/"
    cp /tmp/src/packaging/opnsense/files/usr/local/lib/breeze-core/serve.sh "$P/serve.sh"
    printf "%s\n" "$SHA" > "$P/meow_ac/_commit.txt"
    find "$P" -name "__pycache__" -type d -exec rm -rf {} + 2>/dev/null || true
    "$P/venv/bin/python3.11" -c "import fastapi, uvicorn, msmart, pydantic_core; print(\"  runtime ok, pydantic_core\", pydantic_core.__version__)"
'

# ---------------------------------------------------------- 3. stage the tree
S="$ROOT/tmp/stage"
doas rm -rf "$S"; doas mkdir -p "$S/usr/local/bin" "$S/usr/local/lib"

# ONLY our own subtree. Copying $ROOT/usr/local/lib wholesale drags in everything
# pkg put in the build root — rust's libraries included — turning a 19 MB payload
# into a 168 MB "plugin".
doas cp -R "$ROOT/usr/local/lib/breeze-core" "$S/usr/local/lib/breeze-core"
doas cp -R "$ROOT/tmp/src/packaging/opnsense/files/usr/local/etc" "$S/usr/local/"
doas cp -R "$ROOT/tmp/src/packaging/opnsense/files/usr/local/opnsense" "$S/usr/local/"

# CLI wrapper. meow_ac has no __main__, so `-m meow_ac` fails outright; the CLI
# module is meow_ac.cli, as the BSD installer also uses. The GUI page tells the
# admin to run `breeze-core pair`, so this has to work.
doas sh -c "cat > '$S/usr/local/bin/breeze-core'" <<'WRAP'
#!/bin/sh
# Breeze Core CLI — setup / approve / diag, on the vendored interpreter.
P=/usr/local/lib/breeze-core
export PYTHONPATH="$P"
export AC_CONFIG="${AC_CONFIG:-/usr/local/etc/breeze-core/config.json}"
exec "$P/venv/bin/python3.11" -m meow_ac.cli "$@"
WRAP

# Explicit modes: the source tar is produced on Windows, which records no POSIX
# execute bit. A non-executable serve.sh fails invisibly, because daemon(8) runs
# with -f and the permission error goes to /dev/null.
doas chmod 755 "$S/usr/local/bin/breeze-core" \
     "$S/usr/local/lib/breeze-core/serve.sh" \
     "$S/usr/local/etc/rc.d/breeze_core" \
     "$S/usr/local/opnsense/scripts/OPNsense/BreezeCore/setup.sh"

# -------------------------------------------------------------- 4. manifest
# ABI is read from the chroot, so it is FreeBSD:14:amd64 by construction rather
# than a hardcoded string that can drift.
ABI="$(doas chroot "$ROOT" pkg config ABI)"
doas sh -c "cat > '$ROOT/tmp/manifest.ucl'" <<MANIFEST
name: "os-breeze-core"
version: "$VER"
origin: "opnsense/os-breeze-core"
comment: "Breeze Core — LAN-first control for Midea air conditioners"
desc: <<EOD
Breeze Core runs on this firewall and controls Midea/OEM air conditioners over
the LAN: a REST API plus a web panel, with no cloud dependency after pairing.

Adds Services > Breeze Core to the GUI for enable, bind address, port and service
control. The Python runtime is vendored because OPNsense packages neither the
dependencies nor rust or pip — nothing is ever compiled on the firewall.

Pair air conditioners with 'breeze-core pair'; admit clients with
'breeze-core approve'. Approval is LAN-only by design.
EOD
maintainer: "monikapurpl3@users.noreply.github.com"
www: "https://github.com/monikapurpl3/breeze-core"
abi: "$ABI"
arch: "$ABI"
prefix: "/usr/local"
licenselogic: "single"
licenses: ["MIT"]
categories: ["www", "sysutils"]
deps: {
  python311: { origin: "lang/python311", version: "3.11.0" }
}
scripts: {
  post-install: <<EOS
pw groupshow breeze >/dev/null 2>&1 || pw groupadd breeze -g 8420
pw usershow breeze >/dev/null 2>&1 || pw useradd breeze -u 8420 -g breeze \
    -d /nonexistent -s /usr/sbin/nologin -c "Breeze Core"
install -d -o breeze -g breeze -m 750 /usr/local/etc/breeze-core
# Where configd renders breeze_core -- and the only place besides /etc that
# load_rc_config() will source it from.
install -d -m 755 /usr/local/etc/rc.conf.d
# OPNsense caches the MVC/volt tree, so a new plugin's menu and page do not
# appear until that cache is dropped.
rm -rf /tmp/opnsense_cache_* /var/cache/opnsense-mvc 2>/dev/null || true
echo "===> Breeze Core installed."
echo "     1) Services > Breeze Core: set the listen address, then enable."
echo "     2) breeze-core pair       — discover and pair the air conditioners."
echo "     3) breeze-core approve   — admit a phone or browser (LAN only)."
EOS
  post-deinstall: <<EOS
/usr/local/etc/rc.d/breeze_core onestop >/dev/null 2>&1 || true
echo "===> config kept at /usr/local/etc/breeze-core (remove by hand if unwanted)"
EOS
}
MANIFEST

# ----------------------------------------------------------------- 5. build
# The plist is not optional: given only -M and -r, pkg create packages the
# manifest and nothing else, exits 0, and produces a ~1 KB "package". Generating
# it from the staged tree means it cannot drift from what was actually staged.
doas chroot "$ROOT" /bin/sh -c '
    set -eu
    rm -rf /tmp/pkgout && mkdir -p /tmp/pkgout
    ( cd /tmp/stage && find . -type f -o -type l ) | sed "s|^\.||" | sort > /tmp/plist
    echo "  plist entries: $(wc -l < /tmp/plist | tr -d " ")"
    pkg create -M /tmp/manifest.ucl -r /tmp/stage -p /tmp/plist -o /tmp/pkgout
'
REMOTE

scp -q -o BatchMode=yes "$USER_AT:$ROOT/tmp/pkgout/os-breeze-core-*.pkg" "$OUT/" || {
    echo "no package came back" >&2; exit 1; }

PKG="$(ls -1 "$OUT"/os-breeze-core-*.pkg | tail -1)"
SIZE="$(wc -c < "$PKG")"
# A package that small means the plist was empty or missing — fail loudly rather
# than shipping it.
[ "$SIZE" -gt 1000000 ] || { echo "package is only $SIZE bytes — plist problem" >&2; exit 1; }
echo "==> $(ls -1sh "$PKG")" >&2
