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

ALL=(glibc-amd64 glibc-arm64 musl-amd64 musl-arm64)
TARGETS=("${@:-${ALL[@]}}")

for t in "${TARGETS[@]}"; do
  libc="${t%-*}" arch="${t#*-}"
  echo "=== bundle $libc/$arch (commit $COMMIT) ==="
  docker buildx build \
    --platform "linux/$arch" \
    -f "packaging/binary/Dockerfile.$libc" \
    --build-arg "AC_COMMIT=$COMMIT" \
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
