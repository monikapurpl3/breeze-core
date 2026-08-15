#!/usr/bin/env bash
# Build the four self-contained bundles (glibc/musl x amd64/arm64).
# Run from the REPO ROOT on the workstation (Docker Desktop + buildx; arm64
# goes through QEMU). Artifacts land in packaging/out/bundle-<libc>-<arch>/.
#
#   ./packaging/binary/build-binaries.sh              # all four
#   ./packaging/binary/build-binaries.sh glibc-amd64  # just one
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
COMMIT="$(git rev-parse --short HEAD)"
OUT=packaging/out

ALL=(glibc-amd64 glibc-arm64 musl-amd64 musl-arm64 musl-riscv64)
TARGETS=("${@:-${ALL[@]}}")

# The musl bundle is pinned to Alpine 3.19 for OpenWrt 23.05's musl 1.2.4 floor,
# but Alpine published no riscv64 image before 3.20 — so riscv64 (and only
# riscv64) builds on 3.20. Its musl is 1.2.5, i.e. that bundle targets
# Alpine/Void-musl riscv64, not OpenWrt.
alpine_tag_for() { case "$1" in musl-riscv64) echo 3.20 ;; *) echo 3.19 ;; esac; }

# riscv64 has no musllinux wheels, so its bundle compiles pydantic-core (Rust)
# and friends from source under QEMU — it needs a toolchain in the image, and
# every core it can get.
toolchain_for()  { case "$1" in *-riscv64) echo 1 ;; *) echo 0 ;; esac; }
JOBS="$(nproc 2>/dev/null || echo 4)"

for t in "${TARGETS[@]}"; do
  libc="${t%-*}" arch="${t#*-}"
  echo "=== bundle $libc/$arch (commit $COMMIT) ==="
  docker buildx build \
    --platform "linux/$arch" \
    -f "packaging/binary/Dockerfile.$libc" \
    --build-arg "AC_COMMIT=$COMMIT" \
    --build-arg "ALPINE_TAG=$(alpine_tag_for "$t")" \
    --build-arg "WITH_TOOLCHAIN=$(toolchain_for "$t")" \
    --build-arg "BUILD_JOBS=$JOBS" \
    --cache-to "type=local,dest=$OUT/.buildcache/$t,mode=max" \
    --cache-from "type=local,src=$OUT/.buildcache/$t" \
    -o "type=local,dest=$OUT/bundle-$t" \
    .
  # buildx exports the /breeze-core dir from the scratch stage. Check for a
  # non-empty binary (-s, not -x: extracting to NTFS drops the exec bit —
  # nfpm/tar restore mode 0755 explicitly at packaging time).
  test -s "$OUT/bundle-$t/breeze-core/breeze-core" \
    || { echo "FAIL: no binary in $OUT/bundle-$t"; exit 1; }
  echo "    -> $OUT/bundle-$t/breeze-core"
done

echo "all requested bundles built."
