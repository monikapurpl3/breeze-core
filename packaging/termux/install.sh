#!/data/data/com.termux/files/usr/bin/bash
# Breeze Core in Termux — proof of concept, no root required.
#
#   bash packaging/termux/install.sh
#
# ── Why this is a source install and not a bundle ────────────────────────────
# Android uses Bionic, not glibc or musl, so none of the self-contained bundles
# can run here — not the glibc ones, not the musl ones, not even the arm64 musl
# build that targets the same CPU. Termux has its own Python, so the app is
# installed from source into a venv instead.
#
# ── The one non-obvious dependency ──────────────────────────────────────────
# pydantic-core is a Rust extension with no Android wheel, so it compiles on
# device. That needs `rust`, and it needs ANDROID_API_LEVEL exported, or maturin
# stops with "Failed to determine Android API level" — which is the error you
# get if you just `pip install fastapi` here. Expect 15–40 minutes of compiling
# on a phone, and keep it plugged in.
#
# Rootless throughout: everything lands under $PREFIX, the port is above 1024,
# and nothing needs a system service manager.
set -eu

case "${PREFIX:-}" in
  *com.termux*) : ;;
  *) echo "This installer is for Termux. \$PREFIX doesn't look like Termux."; exit 1 ;;
esac

APP="$PREFIX/opt/breeze-core"
CFG="$PREFIX/etc/breeze-core"
SRC="$(cd "$(dirname "$0")/../.." && pwd)"
KEEP_RUST="${KEEP_RUST:-0}"

echo "==> packages"
# build-essential/binutils are for pycryptodome and the Rust link step.
pkg install -y python rust binutils build-essential

# maturin refuses to guess this, and the failure message doesn't mention pip.
# Ask Android what it actually is, and fall back to Termux's own minimum.
API="$(getprop ro.build.version.sdk 2>/dev/null || true)"
case "$API" in ''|*[!0-9]*) API=24 ;; esac
export ANDROID_API_LEVEL="$API"
echo "    ANDROID_API_LEVEL=$ANDROID_API_LEVEL"

echo "==> app -> $APP"
mkdir -p "$APP" "$CFG"
cp -R "$SRC/meow_ac" "$SRC/static" "$SRC/setup_device.py" "$SRC/requirements.txt" "$APP/"

echo "==> venv + dependencies (the long part)"
python3 -m venv "$APP/venv"
"$APP/venv/bin/pip" install --upgrade pip >/dev/null
# Plain uvicorn, not uvicorn[standard]: the extras pull uvloop, httptools and
# watchfiles, none of which build cleanly here and none of which this needs.
"$APP/venv/bin/pip" install --no-cache-dir \
  fastapi "uvicorn" msmart-ng brotli-asgi

echo "==> wrapper -> $PREFIX/bin/breeze-core"
cat > "$PREFIX/bin/breeze-core" <<WRAP
#!$PREFIX/bin/bash
# Termux wrapper. cd into the app dir so the meow_ac package imports and the
# static/ mount resolves — the same requirement as every other platform.
export AC_CONFIG="\${AC_CONFIG:-$CFG/config.json}"
cd "$APP"
exec "$APP/venv/bin/python" -m meow_ac.cli "\$@"
WRAP
chmod 755 "$PREFIX/bin/breeze-core"

# Optional runit service, if termux-services is installed. No root, no systemd.
if [ -d "$PREFIX/var/service" ]; then
  echo "==> termux-services entry"
  mkdir -p "$PREFIX/var/service/breeze-core"
  cat > "$PREFIX/var/service/breeze-core/run" <<RUN
#!$PREFIX/bin/sh
# Keep the CPU awake, or Android will freeze the process a few minutes after
# the screen goes off and the API will simply stop answering.
termux-wake-lock 2>/dev/null || true
exec breeze-core serve --host 0.0.0.0 --port 8420 2>&1
RUN
  chmod 755 "$PREFIX/var/service/breeze-core/run"
  echo "    sv up breeze-core   (after: sv-enable breeze-core)"
fi

if [ "$KEEP_RUST" = "0" ]; then
  echo "==> reclaiming build tools (KEEP_RUST=1 to keep them)"
  pkg uninstall -y rust >/dev/null 2>&1 || true
fi

cat <<DONE

Installed. Next:

  breeze-core pair                     # find your units, write the config
  breeze-core serve --host 0.0.0.0     # then open http://<phone-ip>:8420

Termux notes, all of which will bite otherwise:
  * termux-wake-lock before serving, or Android freezes it when the screen
    sleeps and the API stops answering.
  * Install Termux:Boot if you want it back after a reboot.
  * Ports below 1024 are unavailable to an unprivileged app; 8420 is fine.
  * The phone needs to stay on the same Wi-Fi as the air conditioners.

Config: $CFG/config.json
DONE
