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
# Refuse to label a stale bundle with this version.
#
# Bundle directories are not cleaned between releases, so an architecture that
# was skipped this time -- riscv64 compiles every dependency from source under
# emulation and takes hours, so it is deliberately skipped -- leaves the previous
# release's binary sitting there, and nfpm will happily wrap it carrying the new
# version number. That shipped as far as the artifact list twice, for 3.1.0 and
# again for 3.2.0, caught by hand both times.
#
# The check is on the VERSION the bundle was built for, not the commit: commits
# land after a build (a docs fix, a packaging fix like this one) without making
# the binaries stale, and comparing to HEAD would reject perfectly good bundles.
WANT_VERSION="$(grep -m1 '^__version__' meow_ac/__init__.py | cut -d'"' -f2)"
KEPT=()
for t in "${TARGETS[@]}"; do
  info="packaging/out/bundle-$t/BUILDINFO"
  if [ ! -f "$info" ]; then
    echo "  SKIPPING $t: no BUILDINFO — built before this check existed, so" >&2
    echo "           its version cannot be confirmed. Rebuild it." >&2
    continue
  fi
  got="$(sed -n 's/^version=//p' "$info" | tr -d '
 ')"
  if [ "$got" != "$WANT_VERSION" ]; then
    echo "  SKIPPING $t: that bundle is version $got, not $WANT_VERSION." >&2
    echo "           Rebuild it with packaging/binary/build-binaries.sh, or accept" >&2
    echo "           that this architecture stays on its previous release." >&2
    continue
  fi
  KEPT+=("$t")
done
TARGETS=("${KEPT[@]}")
[ ${#TARGETS[@]} -gt 0 ] || { echo "no bundle matches version $WANT_VERSION — nothing to package"; exit 1; }

# Docker Desktop on Windows does not always share the drive a bind mount asks
# for: the container starts fine, /work is simply empty, and the only symptom
# is "package-one.sh: No such file or directory". Probe the mount once, and if
# it's a lie, stream the inputs in and the packages out over stdio instead —
# slower, but it works on any Docker regardless of file-sharing settings.
mount_ok() {
  MSYS_NO_PATHCONV=1 docker run --rm -v "$MOUNT:/work" bc-nfpm \
    test -f /work/packaging/nfpm/package-one.sh 2>/dev/null
}

package_mounted() {
  MSYS_NO_PATHCONV=1 docker run --rm -v "$MOUNT:/work" bc-nfpm \
    bash /work/packaging/nfpm/package-one.sh "$1" "$2"
}

package_streamed() {
  libc="$1"; arch="$2"
  # Only what package-one.sh reads: its own scripts, the single bundle being
  # packaged, and the files the tarball embeds. Sending every bundle would
  # push a quarter of a gigabyte through the pipe per target.
  tar -cf - packaging/nfpm packaging/tarball "packaging/out/bundle-$libc-$arch" \
      meow_ac/__init__.py README.md https://github.com/monikapurpl3/breeze-core/wiki/Exposing-it-safely LICENSE \
    | MSYS_NO_PATHCONV=1 docker run -i --rm bc-nfpm bash -c "
        set -e
        mkdir -p /work && tar -xf - -C /work && cd /work
        bash /work/packaging/nfpm/package-one.sh '$libc' '$arch' >&2
        tar -cf - -C /work packaging/out/pkg
      " | tar -xf - -C .
}

if mount_ok; then
  RUN=package_mounted
else
  echo "bind mount unavailable (Docker Desktop file sharing) — streaming instead"
  RUN=package_streamed
fi

for t in "${TARGETS[@]}"; do
  libc="${t%-*}" arch="${t#*-}"
  "$RUN" "$libc" "$arch"
done

echo ""; echo "== packaging/out/pkg =="
ls -la packaging/out/pkg/
