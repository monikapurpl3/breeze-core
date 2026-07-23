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

echo "=== NetBSD pkgin repo ==="
[ -f "$NETBSD_PKG" ] || { echo "missing NetBSD package $NETBSD_PKG"; exit 1; }
rm -rf "$OUT/netbsd"; mkdir -p "$OUT/netbsd/All"
cp "$NETBSD_PKG" "$OUT/netbsd/All/breeze-core-${VER}.tgz"
cp "$NETBSD_SUMMARY" "$OUT/netbsd/All/pkg_summary.gz"
echo "  $(ls "$OUT/netbsd/All" | tr '\n' ' ')"

echo "BSD repos assembled for v$VER under $OUT/{freebsd,netbsd}"
