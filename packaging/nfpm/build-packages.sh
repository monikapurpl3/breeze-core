#!/usr/bin/env bash
# Turn the built bundles (packaging/out/bundle-*) into native packages +
# tarballs, inside the packaging container so file modes are deterministic.
# Run from anywhere on the workstation; artifacts land in packaging/out/pkg/.
#
#   ./packaging/nfpm/build-packages.sh                # every built bundle
#   ./packaging/nfpm/build-packages.sh glibc-amd64    # just one
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO"

docker build -q -t bc-nfpm packaging/nfpm >/dev/null
echo "packaging image ready"

# Repo mount path for Docker Desktop on Windows (git-bash /c/... -> C:/...).
MOUNT="$REPO"
case "$MOUNT" in /[a-z]/*) MOUNT="$(echo "$MOUNT" | sed -E 's#^/([a-z])/#\U\1:/#')" ;; esac

if [ $# -gt 0 ]; then TARGETS=("$@"); else
  TARGETS=()
  for d in packaging/out/bundle-*/; do
    [ -d "$d" ] || continue
    t="$(basename "$d")"; TARGETS+=("${t#bundle-}")
  done
fi
[ ${#TARGETS[@]} -gt 0 ] || { echo "no bundles in packaging/out — run build-binaries.sh first"; exit 1; }

for t in "${TARGETS[@]}"; do
  libc="${t%-*}" arch="${t#*-}"
  MSYS_NO_PATHCONV=1 docker run --rm -v "$MOUNT:/work" bc-nfpm \
    bash /work/packaging/nfpm/package-one.sh "$libc" "$arch"
done

echo ""; echo "== packaging/out/pkg =="
ls -la packaging/out/pkg/
