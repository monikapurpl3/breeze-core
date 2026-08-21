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
BUNDLE_VERSION="$(grep -m1 '^__version__' meow_ac/__init__.py | cut -d'"' -f2)"
OUT=packaging/out

ALL=(glibc-amd64 glibc-arm64 musl-amd64 musl-arm64 musl-riscv64)
TARGETS=("${@:-${ALL[@]}}")

# The musl bundle is pinned to Alpine 3.19 for OpenWrt 23.05's musl 1.2.4 floor,
# but Alpine published no riscv64 image before 3.20 — so riscv64 (and only
# riscv64) builds on 3.20. Its musl is 1.2.5, i.e. that bundle targets
# Alpine/Void-musl riscv64, not OpenWrt.
# riscv64 needs alpine:edge, and the reason is entirely about rustc:
#   3.19  no riscv64 image at all
#   3.20  rust 1.78 ─┐ pydantic-core's Cargo.toml is edition 2024, so cargo
#   3.21  rust 1.83 ─┘ must be >= 1.85: "failed to parse manifest"
#   3.22  rust 1.87   parses, then dies — pydantic-core 2.46.4 and jiter 0.14
#                     declare rust-version 1.88. Short by one minor version.
#   edge  rust 1.97   builds.
# edge is a rolling branch, so this target is deliberately the least
# reproducible of the set; revisit when a stable Alpine ships rustc >= 1.88.
alpine_tag_for() { case "$1" in musl-riscv64) echo edge ;; *) echo 3.19 ;; esac; }

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
  # Record what this bundle IS, for whoever packages it later. Bundle
  # directories are not cleaned between releases, so an architecture skipped
  # this time (riscv64 compiles everything from source under emulation and
  # takes hours) leaves the previous release's binary sitting there -- and nfpm
  # will wrap it carrying the NEW version number. That got caught by hand for
  # 3.1.0 and again for 3.2.0; this is so it does not need catching a third time.
  printf "version=%s\ncommit=%s\nbuilt=%s\n" \
      "$BUNDLE_VERSION" \
      "$COMMIT" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$OUT/bundle-$t/BUILDINFO"
  echo "    -> $OUT/bundle-$t/breeze-core"
done

echo "all requested bundles built."
