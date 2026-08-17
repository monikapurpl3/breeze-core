#!/usr/bin/env bash
# Build a self-contained Breeze Core bundle FOR TERMUX, inside Termux.
#
#   packaging/termux/build-bundle.sh x86_64 > bundle.tar
#   packaging/termux/build-bundle.sh aarch64 > bundle.tar
#
# Run from the repo root on a machine with Docker; it uses the termux-docker
# Android rootfs. x86_64 runs natively, aarch64 goes through QEMU and takes far
# longer (pydantic-core's Rust core compiles under emulation).
#
# ── Why a Termux bundle at all ──────────────────────────────────────────────
# Android is Bionic, so no glibc or musl bundle can run there — not even the
# arm64 musl one, same CPU notwithstanding. Without this, a Termux user has to
# `pkg install rust` and compile pydantic-core on the phone: 15–40 minutes on
# battery. This freezes all of that on a workstation instead.
#
# ── What it is NOT ──────────────────────────────────────────────────────────
# It is a *Termux* bundle, not an Android one. The bootloader is compiled by
# Termux's clang and carries Termux's own interpreter path
# (/data/data/com.termux/files/usr/...), so it runs under Termux and nowhere
# else on the phone. Naming it "bionic-generic" would promise more than it does.
#
# The bundle goes to stdout as a tar; everything else goes to stderr.
set -euo pipefail

ARCH="${1:-x86_64}"
case "$ARCH" in
  x86_64|aarch64) : ;;
  *) echo "arch must be x86_64 or aarch64" >&2; exit 1 ;;
esac
IMAGE="termux/termux-docker:$ARCH"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
COMMIT="$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo unknown)"
JOBS="${POC_JOBS:-$(( $(nproc 2>/dev/null || echo 4) / 2 ))}"

# Is this container going to run under QEMU? x86_64 Termux on an x86_64 host is
# native and fast; aarch64 there is emulated, which changes what's safe inside.
HOST_ARCH="$(uname -m)"
case "$ARCH:$HOST_ARCH" in
  x86_64:x86_64|aarch64:aarch64) EMULATED=0 ;;
  *)                             EMULATED=1 ;;
esac

echo "==> $ARCH via $IMAGE (commit $COMMIT, -j$JOBS, emulated=$EMULATED)" >&2

# Stage A output, if there is any: a directory of wheels cross-built on the host
# by cross-wheel.sh. With it, nothing Rust-shaped ever runs under emulation —
# which is the entire point, because that is precisely what deadlocked here twice.
# See docs/POC-CROSS-BUILDS.md.
WHEELSTAGE=""
if [ -n "${POC_WHEELHOUSE:-}" ]; then
  [ -d "$POC_WHEELHOUSE" ] || { echo "POC_WHEELHOUSE is not a directory: $POC_WHEELHOUSE" >&2; exit 1; }
  ls "$POC_WHEELHOUSE"/*.whl >/dev/null 2>&1 || { echo "no .whl files in $POC_WHEELHOUSE" >&2; exit 1; }
  WHEELSTAGE="$(mktemp -d)"
  mkdir -p "$WHEELSTAGE/wheels"
  cp "$POC_WHEELHOUSE"/*.whl "$WHEELSTAGE/wheels/"
  echo "==> wheelhouse: $(ls -1 "$WHEELSTAGE/wheels" | wc -l) wheel(s) from $POC_WHEELHOUSE" >&2
  ls -1 "$WHEELSTAGE/wheels" | sed 's/^/    /' >&2
fi

# Only what the build needs; the tarball goes in over stdin. An array because the
# wheelhouse adds a second -C, and quoting that inline would word-split wrongly.
TAR_ARGS=(-C "$REPO" meow_ac static setup_device.py requirements.txt
          packaging/binary/launcher.py packaging/binary/breeze-core.spec)
[ -n "$WHEELSTAGE" ] && TAR_ARGS+=(-C "$WHEELSTAGE" wheels)

# Settings travel as a file because docker -e does not survive this image; see
# the note where it is sourced.
ENVSTAGE="$(mktemp -d)"
trap 'rm -rf "$ENVSTAGE" ${WHEELSTAGE:+"$WHEELSTAGE"}' EXIT
{
  echo "POC_EMULATED=$EMULATED"
  echo "POC_CARGO_JOBS=${POC_CARGO_JOBS:-1}"
  echo "POC_HAVE_WHEELS=${WHEELSTAGE:+1}"
  echo "POC_COMMIT=$COMMIT"
} > "$ENVSTAGE/poc-env"
TAR_ARGS+=(-C "$ENVSTAGE" poc-env)

tar -cf - "${TAR_ARGS[@]}" \
  | MSYS_NO_PATHCONV=1 docker run -i --rm --cpus="$JOBS" \
      --name "breeze-poc-$ARCH" \
      "$IMAGE" bash -c '
      # No -e flags here on purpose: this image discards them (see poc-env).
set -eu
exec 3>&1 1>&2          # keep fd 3 for the tar; everything else to stderr

export TMPDIR="${TMPDIR:-$PREFIX/tmp}"; mkdir -p "$TMPDIR"

mkdir -p "$HOME/src" && cd "$HOME/src" && tar -xf -

# Settings arrive as a FILE in the tar, not as docker -e variables.
#
# This is not stylistic. The termux-docker image has an /entrypoint.sh that
# scrubs the environment, so every -e flag is silently discarded: a container run
# with -e MARKER=survived prints MARKER=EMPTY. That means POC_CARGO_JOBS never
# reached a single one of the earlier arm64 attempts — the run believed to be
# throttled to -j1 and the later -j4 "gamble" were BOTH unthrottled, and the
# deadlock conclusions drawn from them were measuring the same thing twice.
# A file in the tar cannot be scrubbed, so this is now sourced first.
set -a; . ./poc-env; set +a
echo "settings: emulated=$POC_EMULATED cargo_jobs=$POC_CARGO_JOBS wheels=$POC_HAVE_WHEELS"

# Throttle native builds when this container is emulated.
#
# qemu-user emulates guest threads, and its futex handling deadlocks under the
# thread churn of a parallel cargo build: the first arm64 attempt stopped dead
# in pydantic-core'"'"'s "Installing build dependencies" (i.e. compiling maturin)
# with six qemu-aarch64-static processes all in state S, 0.02% CPU, and no
# progress ever again. It reads exactly like a slow build and is in fact a hang.
#
# With a cross-built wheelhouse this dial is moot — no cargo runs here at all —
# but it stays for the no-wheelhouse path.
if [ "${POC_EMULATED:-0}" = "1" ]; then
  cj="${POC_CARGO_JOBS:-1}"
  export CARGO_BUILD_JOBS="$cj" MAKEFLAGS="-j$cj"
  echo "emulated target: cargo/make limited to $cj job(s) — qemu futex deadlock territory"
fi

# Termux ships clang, not gcc — which is lucky, because emulated gcc segfaults
# building this bootloader on other odd arches too.
# The termux-docker image ships whichever mirror it was built with — here
# mirrors.zju.edu.cn, which from this network returned Ign: for every package
# and left the build sitting at 0.01% CPU looking like a hang rather than a
# stalled download. Pin the canonical repo instead of inheriting a lottery.
echo "deb https://packages.termux.dev/apt/termux-main stable main"   > "$PREFIX/etc/apt/sources.list"
# ...and then do NOT use `pkg`, which is a wrapper that picks a mirror of its own
# on every invocation and overwrites the pin above. One run pulled from six
# different hosts (krnk.org, cbrx.io, librehat, xvx.my.id, packages-cf, packages)
# and crawled. apt-get honours sources.list and nothing else.
apt-get update -y < /dev/null

# Non-interactive throughout: there is no tty here, so a dpkg config-file
# prompt would block forever, and keeping the old conffile is the right answer
# in a throwaway container anyway.
export DEBIAN_FRONTEND=noninteractive
APT_OPTS="-o Dpkg::Options::=--force-confold -o Dpkg::Options::=--force-confdef"

# Upgrade first: these images are snapshots against a rolling repository, so a
# plain install can hit "held broken packages" (seen as ncurses-ui-libs pinned
# to a version the repo has moved past).
apt-get upgrade -y $APT_OPTS < /dev/null
# Deliberately NOT build-essential: waf drives clang directly, and the meta
# package drags in autotools plus the ncurses tangle above.
#
# rust is installed ONLY when there is no cross-built wheelhouse. It exists here
# for exactly one dependency — pydantic-core — and compiling that under emulation
# is what wedged this build twice. When Stage A has already produced the wheel,
# skipping the package saves both a large download and the deadlock.
PKGS="python clang binutils libffi openssl zlib"
if [ "${POC_HAVE_WHEELS:-}" = "1" ]; then
  echo "cross-built wheels supplied — NOT installing rust"
else
  PKGS="$PKGS rust"
fi
apt-get install -y $APT_OPTS $PKGS < /dev/null

# maturin refuses to guess the API level and the failure never mentions pip.
export ANDROID_API_LEVEL="$(getprop ro.build.version.sdk 2>/dev/null || echo 24)"
echo "ANDROID_API_LEVEL=$ANDROID_API_LEVEL"

python3 -m venv venv
./venv/bin/pip install --upgrade pip

# --only-binary pydantic-core is the load-bearing flag, not --find-links. Without
# it, a wheel whose tag the target pip quietly rejects would fall back to a source
# build and hang for hours; with it, a tag mismatch fails in seconds and says so.
PIP_ARGS=""
if [ "${POC_HAVE_WHEELS:-}" = "1" ] && [ -d "$HOME/src/wheels" ]; then
  echo "installing from the cross-built wheelhouse:"; ls -1 "$HOME/src/wheels" | sed "s/^/    /"
  PIP_ARGS="--find-links $HOME/src/wheels --only-binary pydantic-core"
fi
# Plain uvicorn: the [standard] extras (uvloop, httptools, watchfiles) do not
# build on Bionic and this app does not need them. pycryptodome (msmart-ng) and
# Brotli still compile here on purpose — both are plain C, neither is
# thread-hungry, and pycryptodome built fine under emulation on ppc64le.
./venv/bin/pip install $PIP_ARGS fastapi uvicorn msmart-ng brotli-asgi

# PyInstaller decides "musl or glibc?" by running `ldd --version`, and Android
# ships no ldd at all — so its metadata generation dies with a bare
# FileNotFoundError that mentions neither PyInstaller nor Android. It only wants
# the answer to name a bootloader directory, and the *same* function runs again
# at freeze time, so a stub keeps build and runtime consistent with each other,
# which is all that actually matters here. Deliberately says nothing about musl:
# Bionic is neither, and the glibc-style path is the one that works.
if ! command -v ldd >/dev/null 2>&1; then
  printf "#!%s/bin/sh
echo \"ldd (termux stub) 0\"
" "$PREFIX" > "$PREFIX/bin/ldd"
  chmod 755 "$PREFIX/bin/ldd"
  echo "installed an ldd stub — Android has none, and PyInstaller insists"
fi

# PyInstaller has no Android bootloader, and installing its sdist does not
# build one — waf has to be run explicitly, WITH the configure step, or it
# reports success in milliseconds having compiled nothing.
./venv/bin/pip download --no-binary :all: --no-deps -d "$TMPDIR/pyi" pyinstaller
tar -xzf "$TMPDIR"/pyi/pyinstaller-*.tar.gz -C "$TMPDIR/pyi"
cd "$TMPDIR"/pyi/pyinstaller-*/bootloader
CC=clang python3 ./waf distclean all
cd .. && "$HOME/src/venv/bin/pip" install .
cd "$HOME/src"

cp packaging/binary/launcher.py packaging/binary/breeze-core.spec .
echo "'"$COMMIT"'" > meow_ac/_commit.txt
./venv/bin/pyinstaller --clean --distpath dist breeze-core.spec

# Prove it on the target before shipping it.
./dist/breeze-core/breeze-core version

tar -cf - -C dist breeze-core >&3
'
echo "==> done" >&2
