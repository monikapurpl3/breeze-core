#!/usr/bin/env bash
# Proof-of-concept bundles for architectures outside the supported set:
# s390x, ppc64le, mips64le. Frozen at a tag (v3.0.5 as shipped) — these are
# "it runs" demonstrations, not release artifacts, and nothing else in the
# packaging pipeline knows about them.
#
#   ./packaging/binary/build-poc.sh                 # every target, in turn
#   ./packaging/binary/build-poc.sh s390x           # just one
#   POC_JOBS=8 ./packaging/binary/build-poc.sh      # be gentler still
#
# ── Why this is strictly sequential ──────────────────────────────────────────
# Every one of these runs under QEMU user-mode emulation, where each compile
# job is a separate emulated, single-threaded process. Two builds at
# `-j$(nproc)` each therefore put ~2x the thread count of emulated processes on
# the CPU: the machine thrashes, the desktop stutters, and *both* builds finish
# later than if they had been run one after the other. Learned the hard way.
# One build at a time, and not even that one gets every core.
set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"; cd "$REPO"

# Half the machine by default, leaving the other half for whoever is using it.
NPROC="$(nproc 2>/dev/null || echo 4)"
JOBS="${POC_JOBS:-$(( NPROC / 2 ))}"
[ "$JOBS" -lt 2 ] && JOBS=2

OUT="packaging/out/poc"
LOGS="$OUT/logs"
mkdir -p "$LOGS"
COMMIT="$(git rev-parse --short HEAD)"
VER="$(sed -n 's/^__version__ = "\(.*\)"/\1/p' meow_ac/__init__.py)"

# musl targets, built from Dockerfile.musl on alpine:edge.
#
# edge and not 3.19 for the same reason riscv64 needs it: neither s390x nor
# ppc64le has musllinux wheels for pydantic-core, so it compiles from source,
# and that needs cargo >= 1.85 (edition 2024) plus rustc >= 1.88. Alpine 3.19
# ships rust 1.76 and fails an hour into the build. The OpenWrt musl-1.2.4
# floor that pins the *supported* musl bundles to 3.19 is irrelevant here.
ALL_MUSL="s390x ppc64le"

usage() { echo "targets: $ALL_MUSL mips64le  (default: all)"; }

# Don't test for the execute bit. buildx exports to the host filesystem, and on
# Windows that filesystem carries no POSIX modes — so a bundle that built fine
# and printed its own version during the build still shows up as -rw-r--r--,
# and `[ -x ]` reports a false failure. Size is the honest check here; the
# Dockerfile already ran `breeze-core version` inside the container, which is
# the real proof it works on the target architecture.
built_ok() {
  [ -s "$1/breeze-core/breeze-core" ] || return 1
  # A truncated or empty export would still be a file; the real bundle is MBs.
  [ "$(wc -c < "$1/breeze-core/breeze-core")" -gt 1000000 ]
}

build_musl() {
  local arch="$1"
  local dest="$OUT/bundle-musl-$arch" log="$LOGS/$arch.log"
  if built_ok "$dest"; then
    echo "  $arch: already built, skipping (rm -rf $dest to redo)"
    return 0
  fi
  echo "  $arch: building with -j$JOBS on $NPROC threads — see $log"
  local start=$SECONDS
  MSYS_NO_PATHCONV=1 docker buildx build --platform "linux/$arch" \
    -f packaging/binary/Dockerfile.musl \
    --build-arg AC_COMMIT="$COMMIT" \
    --build-arg ALPINE_TAG=edge \
    --build-arg WITH_TOOLCHAIN=1 \
    --build-arg BUILD_JOBS="$JOBS" \
    -o "type=local,dest=$dest" . > "$log" 2>&1
  local rc=$? mins=$(( (SECONDS - start) / 60 ))
  if [ $rc -eq 0 ] && built_ok "$dest"; then
    echo "  $arch: done in ${mins}m"
  else
    echo "  $arch: FAILED after ${mins}m — tail of $log:"
    tail -5 "$log" | sed 's/^/      /'
    return 1
  fi
}

build_mips64le() {
  local dest="$OUT/bundle-glibc-mips64le" log="$LOGS/mips64le.log"
  if built_ok "$dest"; then
    echo "  mips64le: already built, skipping"
    return 0
  fi
  # glibc, not musl: Alpine has no MIPS port at all, so the only usable base is
  # Debian's mips64el port. Also 64-bit only — the binfmt set covers mips64 and
  # mips64le, not 32-bit mips/mipsel, which is what most small routers are.
  echo "  mips64le: building with -j$JOBS — see $log"
  local start=$SECONDS
  MSYS_NO_PATHCONV=1 docker buildx build --platform linux/mips64le \
    -f packaging/binary/Dockerfile.mips \
    --build-arg AC_COMMIT="$COMMIT" \
    --build-arg BUILD_JOBS="$JOBS" \
    -o "type=local,dest=$dest" . > "$log" 2>&1
  local rc=$? mins=$(( (SECONDS - start) / 60 ))
  if [ $rc -eq 0 ] && built_ok "$dest"; then
    echo "  mips64le: done in ${mins}m"
  else
    echo "  mips64le: FAILED after ${mins}m — tail of $log:"
    tail -5 "$log" | sed 's/^/      /'
    return 1
  fi
}

TARGETS=("$@")
[ ${#TARGETS[@]} -eq 0 ] && TARGETS=($ALL_MUSL mips64le)

echo "proof-of-concept bundles for $VER ($COMMIT), one at a time"
for t in "${TARGETS[@]}"; do
  case "$t" in
    s390x|ppc64le) build_musl "$t" ;;
    mips64le)      build_mips64le ;;
    -h|--help)     usage; exit 0 ;;
    *)             echo "  unknown target: $t"; usage; exit 1 ;;
  esac
done

echo ""
echo "== $OUT =="
for d in "$OUT"/bundle-*/; do
  [ -d "$d" ] || continue
  b="$d/breeze-core/breeze-core"
  [ -s "$b" ] && echo "  $(basename "$d"): $(du -sh "$d" | cut -f1)"
done
