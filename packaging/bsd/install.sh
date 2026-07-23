#!/bin/sh
# Breeze Core — source installer for the BSDs (FreeBSD / OpenBSD / NetBSD).
#
# The Linux self-contained bundles are Linux ELF binaries and can't run on a
# BSD kernel, so BSD installs from source into a private virtualenv — the same
# app (`meow_ac.app:app`), just built on the host. This script does the whole
# thing: service user, venv + deps, a `breeze-core` wrapper, the rc.d service,
# and the editable env file. Run it from a checkout (or unpacked source
# tarball) as root:
#
#   doas sh packaging/bsd/install.sh      # OpenBSD
#   sh   packaging/bsd/install.sh         # FreeBSD / NetBSD (as root)
#
set -eu

HERE="$(cd "$(dirname "$0")/../.." && pwd)"   # repo root (meow_ac/, static/, …)
OS="$(uname -s)"

say() { printf '[breeze] %s\n' "$*"; }
die() { printf '[breeze] ERROR: %s\n' "$*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die "run as root (doas/su)"

# --- per-OS layout ----------------------------------------------------------
case "$OS" in
  FreeBSD)
    PREFIX=/usr/local; ETCDIR=/usr/local/etc/breeze-core; RCDIR=/usr/local/etc/rc.d
    RC_SRC="$HERE/packaging/bsd/rc.freebsd"; NOLOGIN=/usr/sbin/nologin ;;
  OpenBSD)
    PREFIX=/usr/local; ETCDIR=/etc/breeze-core; RCDIR=/etc/rc.d
    RC_SRC="$HERE/packaging/bsd/rc.openbsd"; NOLOGIN=/sbin/nologin ;;
  NetBSD)
    PREFIX=/usr/pkg; ETCDIR=/usr/pkg/etc/breeze-core; RCDIR=/etc/rc.d
    RC_SRC="$HERE/packaging/bsd/rc.netbsd"; NOLOGIN=/sbin/nologin ;;
  *) die "unsupported OS '$OS' — this installer is for FreeBSD/OpenBSD/NetBSD" ;;
esac
APPDIR="$PREFIX/breeze-core"
BIN="$PREFIX/bin/breeze-core"

# --- python -----------------------------------------------------------------
PY="$(command -v python3.12 || command -v python3.11 || command -v python3 || true)"
[ -n "$PY" ] || die "python 3.11+ not found — install it first (e.g. FreeBSD: pkg install python311; OpenBSD: pkg_add python%3.11; NetBSD: pkgin install python311)"
say "using $PY ($("$PY" --version 2>&1))"

# --- service user -----------------------------------------------------------
if ! getent group breeze >/dev/null 2>&1 && ! grep -q '^breeze:' /etc/group 2>/dev/null; then
  case "$OS" in
    FreeBSD) pw groupadd breeze ;;
    *)       groupadd breeze ;;
  esac
fi
if ! id breeze >/dev/null 2>&1; then
  case "$OS" in
    FreeBSD) pw useradd breeze -g breeze -d "$ETCDIR" -s "$NOLOGIN" -c "Breeze Core" ;;
    *)       useradd -g breeze -d "$ETCDIR" -s "$NOLOGIN" breeze ;;
  esac
fi

# --- program + venv ---------------------------------------------------------
say "installing app to $APPDIR"
mkdir -p "$APPDIR"
cp -R "$HERE/meow_ac" "$APPDIR/"
cp -R "$HERE/static" "$APPDIR/"
cp "$HERE/setup_device.py" "$APPDIR/"

say "building virtualenv (this compiles a couple of native deps — give it a minute)"
"$PY" -m venv "$APPDIR/venv"
"$APPDIR/venv/bin/pip" install --upgrade pip >/dev/null
# Plain `uvicorn` (not [standard]): uvloop/httptools are Linux-focused and
# unnecessary — the app runs fine on the stock asyncio loop.
"$APPDIR/venv/bin/pip" install "fastapi>=0.110" "uvicorn>=0.29" "msmart-ng>=2026.4.1" "brotli-asgi>=1.4"

# --- breeze-core wrapper ----------------------------------------------------
cat > "$BIN" <<EOF
#!/bin/sh
# Breeze Core CLI (serve / pair / diag / approve / …) — BSD source install.
export AC_CONFIG="\${AC_CONFIG:-$ETCDIR/config.json}"
export PYTHONPATH="$APPDIR"
exec "$APPDIR/venv/bin/python" -m meow_ac.cli "\$@"
EOF
chmod 755 "$BIN"

# --- state dir + env --------------------------------------------------------
mkdir -p "$ETCDIR"
[ -f "$ETCDIR/breeze-core.env" ] || cp "$HERE/packaging/nfpm/breeze-core.env" "$ETCDIR/breeze-core.env"
chown -R breeze:breeze "$ETCDIR"
chmod 750 "$ETCDIR"

# --- rc.d service -----------------------------------------------------------
[ -f "$RC_SRC" ] || die "missing rc script $RC_SRC"
install -m 0755 "$RC_SRC" "$RCDIR/breeze_core"

"$BIN" version >/dev/null || die "installed binary failed to run"

case "$OS" in
  FreeBSD) ENABLE="sysrc breeze_core_enable=YES"; START="service breeze_core start" ;;
  OpenBSD) ENABLE="rcctl enable breeze_core";     START="rcctl start breeze_core" ;;
  NetBSD)  ENABLE="echo breeze_core=YES >> /etc/rc.conf"; START="service breeze_core start" ;;
esac

cat <<EOF

  Breeze Core installed on $OS.

  1. Pair your AC units:      breeze-core pair
  2. Set your LAN IP in       $ETCDIR/breeze-core.env   (BREEZE_HOST=...)
  3. Enable + start:          $ENABLE && $START

  Then open http://<BREEZE_HOST>:8420. Strongest isolation on BSD is a jail
  (FreeBSD) / pledge-style confinement — see HARDENING.md.
EOF
