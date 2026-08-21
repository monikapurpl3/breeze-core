#!/usr/bin/env bash
# Stage 0b of the cross-build plan: export a cross toolchain sysroot FROM the
# Termux image, so native wheels can be built on the host at full speed.
#
#   packaging/termux/export-sysroot.sh aarch64 > termux-sysroot-aarch64.tar
#
# ── Why this is small, and why there is no NDK download ──────────────────────
# https://github.com/monikapurpl3/breeze-core/wiki/Proof-of-concept-architectures assumed cross-building for Android meant fetching the
# ~700 MB Android NDK. probe-target.sh showed otherwise: Termux ships an
# `ndk-sysroot` package (r29, API 24) because on-device compilation is a
# first-class use case there — clang plus that sysroot is how Termux users build
# native code on a phone. It comes in as a dependency of `python` and is a few
# megabytes. Pulling it out gives us the Bionic headers, the stub libs and crt
# objects, which is exactly what a host clang needs to emit Android objects.
#
# Also exported: libpython3.14.so and friends. Android's linker refuses
# undefined symbols in shared objects, so a CPython extension module must link
# libpython explicitly — unlike glibc/musl, where leaving them undefined is
# normal. Nothing links without it.
#
# The tar goes to stdout; the manifest goes to stderr.
set -euo pipefail

ARCH="${1:-aarch64}"
case "$ARCH" in
  aarch64|x86_64) : ;;
  *) echo "arch must be aarch64 or x86_64" >&2; exit 1 ;;
esac

echo "==> exporting cross sysroot from termux/termux-docker:$ARCH" >&2

MSYS_NO_PATHCONV=1 docker run -i --rm --name "breeze-sysroot-$ARCH" \
    "termux/termux-docker:$ARCH" bash -c '
set -eu
exec 3>&1 1>&2

export TMPDIR="${TMPDIR:-$PREFIX/tmp}"; mkdir -p "$TMPDIR"
echo "deb https://packages.termux.dev/apt/termux-main stable main" > "$PREFIX/etc/apt/sources.list"
export DEBIAN_FRONTEND=noninteractive
APT_OPTS="-o Dpkg::Options::=--force-confold -o Dpkg::Options::=--force-confdef"
pkg upgrade -y $APT_OPTS < /dev/null >/dev/null 2>&1 || true
# ndk-sysroot arrives with python anyway; name it explicitly so this does not
# silently depend on that staying true.
pkg install -y $APT_OPTS python ndk-sysroot < /dev/null

V="$(python3 -c "import sys;print(f\"{sys.version_info.major}.{sys.version_info.minor}\")")"
echo "--- where ndk-sysroot actually installs (this decides --sysroot) ---"
dpkg -L ndk-sysroot | grep -vE "/(share|doc)/" | sed -n "1,12p"
echo "  ... $(dpkg -L ndk-sysroot | wc -l) paths total"
echo "--- crt objects present? (linking fails without them) ---"
find "$PREFIX" -name "crtbegin_so.o" -o -name "crtend_so.o" 2>/dev/null | head -4 || echo "  none found"
echo "--- python minor: $V ---"

echo "--- Bionic system libs (ndk-sysroot does NOT ship these) ---"
ls /system/lib64/libc.so /system/lib64/libm.so /system/lib64/libdl.so /system/lib64/liblog.so 2>&1 | head -5

# Everything a host clang + rustc needs pointed at. $PREFIX-relative so the
# consumer can rebuild the same absolute layout under any prefix it likes.
#
# Two directories, and the second one is easy to miss: ndk-sysroot supplies the
# headers, the crt objects and the Termux stubs, but NOT libc/libm/libdl/liblog
# — on-device, clang under Termux links straight against the real Android system
# libraries in /system/lib64. Without them the link dies on undefined references
# to every libc symbol, which reads like a broken sysroot rather than a missing
# one. They go in under system/ so the consumer can add a second -L.
# (No apostrophes in this block on purpose: it lives inside a single-quoted
# script passed to bash -c, where one would end the quoting mid-comment.)
cd "$PREFIX"
tar -cf - \
    include \
    lib/libpython"$V".so lib/libpython3.so \
    lib/libandroid-support.so \
    lib/libandroid-posix-semaphore.so \
    lib/libcrypt.so \
    lib/python"$V"/_sysconfigdata*.py \
    $(dpkg -L ndk-sysroot | sed -n "s|^$PREFIX/||p" | grep -E "^(lib|include)/" | grep -v "/$" || true) \
    -C / \
    system/lib64/libc.so system/lib64/libm.so system/lib64/libdl.so \
    system/lib64/liblog.so system/lib64/libc++.so \
    2>/dev/null >&3
'
echo "==> sysroot exported" >&2
