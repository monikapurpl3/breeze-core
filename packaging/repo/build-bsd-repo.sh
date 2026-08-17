#!/usr/bin/env bash
# Assemble the BSD sections of the package repo into packaging/out/repo/,
# alongside the Linux repos from build-repo.sh. Run AFTER build-repo.sh (which
# wipes+recreates packaging/out/repo/), then publish.sh.
#
#   packaging/out/repo/
#   ├── freebsd/  breeze-core-<v>.pkg + meta.conf + packagesite.pkg + data.pkg
#   │             + breeze-freebsd-repo.rsa.pub   (pkg(8), RSA-signed catalog)
#   └── netbsd/All/  breeze-core-<v>.tgz + pkg_summary.gz   (pkgin)
#
# The BSD binary packages + FreeBSD catalog can only be produced on real BSD
# hosts (a Linux box can't run FreeBSD `pkg repo` or NetBSD `pkg_create`):
#   FreeBSD: install.sh → mkpkg-freebsd.sh → breeze-core-<v>.pkg, then
#            `pkg repo <dir> packaging/repo/keys/breeze-freebsd-repo.rsa`
#            → meta.conf, packagesite.pkg, data.pkg (catalog signed w/ that key)
#   NetBSD:  install.sh → mkpkg-netbsd.sh → breeze-core-<v>.tgz, then
#            `pkg_info -X breeze-core-<v>.tgz | gzip -9 > pkg_summary.gz`
# This script only stages those pre-built artifacts + the FreeBSD pubkey.
#
# Inputs (override via env):
#   FREEBSD_REPO_DIR  dir holding the signed FreeBSD catalog + .pkg
#   NETBSD_PKG        the NetBSD binary package (.tgz)
#   NETBSD_SUMMARY    the NetBSD pkg_summary.gz
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"; cd "$REPO"
VER="$(sed -n 's/^__version__ = "\(.*\)"/\1/p' meow_ac/__init__.py)"
OUT="packaging/out/repo"
KEYS="packaging/repo/keys"
FREEBSD_REPO_DIR="${FREEBSD_REPO_DIR:-packaging/out/bsd/freebsd}"
NETBSD_PKG="${NETBSD_PKG:-packaging/out/bsd/breeze-core-${VER}.tgz}"
NETBSD_SUMMARY="${NETBSD_SUMMARY:-packaging/out/bsd/pkg_summary.gz}"

[ -f "$OUT/index.html" ] || { echo "run build-repo.sh first (no $OUT/index.html)"; exit 1; }

echo "=== FreeBSD pkg repo ==="
[ -f "$FREEBSD_REPO_DIR/packagesite.pkg" ] || { echo "missing FreeBSD catalog in $FREEBSD_REPO_DIR"; exit 1; }
rm -rf "$OUT/freebsd"; mkdir -p "$OUT/freebsd"
cp "$FREEBSD_REPO_DIR"/* "$OUT/freebsd/"   # .pkg + meta.conf + meta + packagesite.pkg + data.pkg
cp "$KEYS/breeze-freebsd-repo.rsa.pub" "$OUT/freebsd/breeze-freebsd-repo.rsa.pub"
echo "  $(ls "$OUT/freebsd" | tr '\n' ' ')"

echo "=== source tarball (OpenBSD / any from-source install) ==="
# OpenBSD gets no binary package — pkg_create there wants a ports-style packing
# list, and the Linux bundles are ELF binaries that can't run on a BSD kernel.
# So publish the source next to the repos and let packaging/bsd/install.sh do
# the work; the landing page's OpenBSD section fetches exactly this path.
rm -rf "$OUT/src"; mkdir -p "$OUT/src"
if git -C . rev-parse --git-dir >/dev/null 2>&1; then
  git archive --format=tar.gz --prefix="breeze-core/" \
    -o "$OUT/src/breeze-core-${VER}.tar.gz" HEAD
else
  echo "  (not a git checkout — skipping source tarball)"
fi
[ -f "$OUT/src/breeze-core-${VER}.tar.gz" ] && \
  echo "  breeze-core-${VER}.tar.gz ($(wc -c < "$OUT/src/breeze-core-${VER}.tar.gz") bytes)"

echo "=== NetBSD pkgin repo ==="
[ -f "$NETBSD_PKG" ] || { echo "missing NetBSD package $NETBSD_PKG"; exit 1; }
rm -rf "$OUT/netbsd"; mkdir -p "$OUT/netbsd/All"
cp "$NETBSD_PKG" "$OUT/netbsd/All/breeze-core-${VER}.tgz"
cp "$NETBSD_SUMMARY" "$OUT/netbsd/All/pkg_summary.gz"
echo "  $(ls "$OUT/netbsd/All" | tr '\n' ' ')"

echo "=== Android app (optional) ==="
# The APK is built from the *breeze* repo, not this one, so it's staged from a
# path given at call time. It lives here rather than being copied straight into
# the published tree because build-repo.sh wipes $OUT on every run — anything
# dropped in by hand would silently disappear on the next rebuild.
#   ANDROID_APK=/path/to/Breeze-2.1.2.apk ./packaging/repo/build-bsd-repo.sh
if [ -n "${ANDROID_APK:-}" ] && [ -f "$ANDROID_APK" ]; then
  mkdir -p "$OUT/android"
  base="$(basename "$ANDROID_APK")"
  cp "$ANDROID_APK" "$OUT/android/$base"
  # A stable name so the landing page can link to "latest" without editing.
  cp "$ANDROID_APK" "$OUT/android/breeze-latest.apk"
  ( cd "$OUT/android" && sha256sum breeze-latest.apk > breeze-latest.apk.sha256 \
      && sha256sum "$base" > "$base.sha256" )
  chmod 644 "$OUT/android"/*
  echo "  $base + breeze-latest.apk (+ sha256)"
else
  echo "  (no ANDROID_APK given — skipping)"
fi

echo "=== Windows installer + winget manifests (optional) ==="
# The .exe is the one artifact CI can't build (makensis needs Windows), so it
# arrives by path like the APK does. Same reason it's staged here rather than
# dropped into the published tree: build-repo.sh wipes $OUT on every run.
if [ -n "${WINDOWS_EXE:-}" ] && [ -f "$WINDOWS_EXE" ]; then
  mkdir -p "$OUT/windows"
  cp "$WINDOWS_EXE" "$OUT/windows/Breeze-Core-Setup-${VER}.exe"
  cp "$WINDOWS_EXE" "$OUT/windows/Breeze-Core-Setup.exe"
  ( cd "$OUT/windows" \
      && sha256sum "Breeze-Core-Setup.exe" > "Breeze-Core-Setup.exe.sha256" \
      && sha256sum "Breeze-Core-Setup-${VER}.exe" > "Breeze-Core-Setup-${VER}.exe.sha256" )
  chmod 644 "$OUT/windows"/*
  echo "  Breeze-Core-Setup-${VER}.exe (+ latest, + sha256)"
else
  echo "  (no WINDOWS_EXE given — skipping)"
fi

# winget manifests are source, not build output, so they're always published.
if [ -d packaging/winget ]; then
  rm -rf "$OUT/winget"; mkdir -p "$OUT/winget"
  cp -R packaging/winget/. "$OUT/winget/"
  find "$OUT/winget" -type f -exec chmod 644 {} +
  echo "  winget manifests: $(ls packaging/winget | tr '\n' ' ')"
fi

echo "=== proof-of-concept builds (optional) ==="
# Frozen at whatever tag they were built from, deliberately outside the signed
# repositories: these are developer aids, not packages anyone should install
# from a package manager. Staged here like the APK and the .exe because
# build-repo.sh wipes $OUT on every run.
#   POC_DIR=/path/with/tarballs ./packaging/repo/build-bsd-repo.sh
if [ -n "${POC_DIR:-}" ] && [ -d "$POC_DIR" ]; then
  rm -rf "$OUT/poc"; mkdir -p "$OUT/poc"
  found=0
  for f in "$POC_DIR"/*.tar.gz "$POC_DIR"/*.tar; do
    [ -f "$f" ] || continue
    cp "$f" "$OUT/poc/"
    found=$((found + 1))
  done
  if [ "$found" -gt 0 ]; then
    ( cd "$OUT/poc" && for f in *; do
        case "$f" in *.sha256) continue ;; esac
        sha256sum "$f" > "$f.sha256"
      done )
    chmod 644 "$OUT/poc"/*
    echo "  $found artifact(s):"
    ls "$OUT/poc" | grep -v '\.sha256$' | sed 's/^/    /'
  else
    rmdir "$OUT/poc" 2>/dev/null || true
    echo "  (POC_DIR held no tarballs)"
  fi
else
  echo "  (no POC_DIR given — skipping)"
fi

echo "BSD repos assembled for v$VER under $OUT/{freebsd,netbsd}"
