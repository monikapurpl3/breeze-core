#!/usr/bin/env bash
# Install-test matrix: install the built packages on real distro images and
# verify the binary + service basics. This is the "does it actually work on
# Mint/Devuan/Tumbleweed/Artix/…" pass — run it on the workstation after
# build-binaries.sh + build-packages.sh.
#
#   ./packaging/test/test-matrix.sh            # full matrix
#   ./packaging/test/test-matrix.sh debian arch   # subset (name match)
#
# Each target: install package -> `breeze-core version` -> `serve` comes up
# (checks the uvicorn startup line; no curl/python assumptions on the image)
# -> service user + /etc/breeze-core perms exist.
set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO"
VER="$(sed -n 's/^__version__ = "\(.*\)"/\1/p' meow_ac/__init__.py)"
PKG="packaging/out/pkg"
LOGS="packaging/out/test-logs"; mkdir -p "$LOGS"

MOUNT="$REPO"
case "$MOUNT" in /[a-z]/*) MOUNT="$(echo "$MOUNT" | sed -E 's#^/([a-z])/#\U\1:/#')" ;; esac

DEB_AMD="$PKG/breeze-core_${VER}_amd64.deb"
DEB_ARM="$PKG/breeze-core_${VER}_arm64.deb"
RPM_AMD="$PKG/breeze-core-${VER}-1.x86_64.rpm"
PAC_AMD="$PKG/breeze-core-${VER}-1-x86_64.pkg.tar.zst"
APK_AMD="$PKG/breeze-core_${VER}_x86_64.apk"
TAR_GLIBC_AMD="$PKG/breeze-core-${VER}-linux-glibc-amd64.tar.gz"
TAR_MUSL_AMD="$PKG/breeze-core-${VER}-linux-musl-amd64.tar.gz"

# name|platform|image|install command (package paths are /pkg/<file>)
TARGETS=(
  "debian|linux/amd64|debian:bookworm-slim|dpkg -i /pkg/$(basename "$DEB_AMD")"
  "ubuntu|linux/amd64|ubuntu:24.04|dpkg -i /pkg/$(basename "$DEB_AMD")"
  "mint|linux/amd64|linuxmintd/mint22-amd64|dpkg -i /pkg/$(basename "$DEB_AMD")"
  "devuan|linux/amd64|devuan/devuan:daedalus|dpkg -i /pkg/$(basename "$DEB_AMD")"
  "debian-arm64|linux/arm64|debian:bookworm-slim|dpkg -i /pkg/$(basename "$DEB_ARM")"
  "leap|linux/amd64|opensuse/leap:15.6|rpm -ivh /pkg/$(basename "$RPM_AMD")"
  "tumbleweed|linux/amd64|opensuse/tumbleweed|rpm -ivh /pkg/$(basename "$RPM_AMD")"
  "sle-bci|linux/amd64|registry.suse.com/bci/bci-base:15.6|rpm -ivh /pkg/$(basename "$RPM_AMD")"
  "alma|linux/amd64|almalinux:9|rpm -ivh /pkg/$(basename "$RPM_AMD")"
  "arch|linux/amd64|archlinux:base|pacman -U --noconfirm /pkg/$(basename "$PAC_AMD")"
  "manjaro|linux/amd64|manjarolinux/base|pacman -U --noconfirm /pkg/$(basename "$PAC_AMD")"
  "artix|linux/amd64|artixlinux/artixlinux:latest|pacman -U --noconfirm /pkg/$(basename "$PAC_AMD")"
  "alpine|linux/amd64|alpine:3.20|apk add --allow-untrusted /pkg/$(basename "$APK_AMD")"
  "void-musl|linux/amd64|ghcr.io/void-linux/void-musl:latest|xbps-install -Sy tar gzip shadow >/dev/null 2>&1; tar -xzf /pkg/$(basename "$TAR_MUSL_AMD") -C /tmp && /tmp/breeze-core-${VER}-linux-musl-amd64/install.sh"
  "gentoo|linux/amd64|gentoo/stage3:latest|tar -xzf /pkg/$(basename "$TAR_GLIBC_AMD") -C /tmp && /tmp/breeze-core-${VER}-linux-glibc-amd64/install.sh"
)

run_target() {
  local name="$1" platform="$2" image="$3" install="$4"
  local log="$LOGS/$name.log"
  MSYS_NO_PATHCONV=1 docker run --rm --platform "$platform" \
    -v "$MOUNT/$PKG:/pkg:ro" "$image" sh -c '
set -e
'"$install"'
echo "--- version ---"
breeze-core version
echo "--- user/perms ---"
id breeze >/dev/null 2>&1 && echo "user: ok"
[ "$(stat -c %a /etc/breeze-core 2>/dev/null)" = "750" ] && echo "etc perms: 750"
echo "--- serve ---"
(AC_CONFIG=/tmp/c.json breeze-core serve --host 127.0.0.1 --port 8420 >/tmp/s.log 2>&1 &)
i=0; while [ $i -lt 15 ]; do grep -q "Uvicorn running" /tmp/s.log && break; i=$((i+1)); sleep 1; done
grep -q "Uvicorn running" /tmp/s.log && echo "serve: up" || { echo "serve: FAILED"; cat /tmp/s.log; exit 1; }
' > "$log" 2>&1
  local rc=$?
  if [ $rc -eq 0 ] && grep -q "serve: up" "$log" && grep -q "Breeze Core $VER" "$log"; then
    echo "PASS  $name"
  else
    echo "FAIL  $name  (see $log)"
    return 1
  fi
}

FILTER=("$@")
PASS=0; FAIL=0; FAILED=()
for t in "${TARGETS[@]}"; do
  IFS='|' read -r name platform image install <<< "$t"
  if [ ${#FILTER[@]} -gt 0 ]; then
    keep=0; for f in "${FILTER[@]}"; do [[ "$name" == *"$f"* ]] && keep=1; done
    [ $keep -eq 1 ] || continue
  fi
  if run_target "$name" "$platform" "$image" "$install"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); FAILED+=("$name"); fi
done

echo ""
echo "== matrix: $PASS pass, $FAIL fail =="
[ $FAIL -eq 0 ] || { printf 'failed: %s\n' "${FAILED[*]}"; exit 1; }
