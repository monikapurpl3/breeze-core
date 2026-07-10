#!/usr/bin/env bash
# Runs INSIDE the packaging container (see Dockerfile + build-packages.sh).
# Stages one bundle with normalized modes, then emits the native packages and
# the tarball for it.
#
#   package-one.sh <libc> <arch>       e.g. package-one.sh glibc amd64
set -euo pipefail

LIBC="$1" ARCH="$2"
cd /work
BC_VERSION="$(sed -n 's/^__version__ = "\(.*\)"/\1/p' meow_ac/__init__.py)"
BUNDLE="packaging/out/bundle-$LIBC-$ARCH/breeze-core"
OUT="packaging/out/pkg"
mkdir -p "$OUT"
[ -d "$BUNDLE" ] || { echo "missing bundle: $BUNDLE"; exit 1; }

# --- stage with sane modes (the Windows checkout loses the exec bit) --------
# -L dereferences symlinks: apk-tools rejects packages where nfpm's tree walk
# hits a symlink ("package file format error"), and PyInstaller bundles carry
# one (libgcc_s -> watchfiles.libs/...). Copying the ~100KB twice is cheaper
# than a broken Alpine package; it also makes the tarball layout mount-proof.
STAGE=/stage
rm -rf "$STAGE"; mkdir -p "$STAGE"
cp -RL "$BUNDLE" "$STAGE/breeze-core"
find "$STAGE" -type d -exec chmod 755 {} +
find "$STAGE" -type f -exec chmod 644 {} +
chmod 755 "$STAGE/breeze-core/breeze-core"

export BC_VERSION BC_ARCH="$ARCH"

# --- native packages ---------------------------------------------------------
# apk needs a variant config: nfpm 2.47's apk packager writes an invalid
# archive for `type: tree` entries (apk-tools: "package file format error"),
# so we expand the bundle into explicit per-file entries, which work.
# Reported upstream: https://github.com/goreleaser/nfpm/issues/1112 — drop
# this (and the BEGIN/END-BUNDLE-TREE markers in nfpm.yaml) once a release
# fixes it and NFPM_VERSION is bumped in the Dockerfile.
gen_apk_yaml() {
  local out="$1" entries=/tmp/entries.yaml
  : > "$entries"
  find "$STAGE/breeze-core" -type f | LC_ALL=C sort | while read -r f; do
    printf -- '  - src: %s\n    dst: /usr/lib/breeze-core/%s\n' \
      "$f" "${f#"$STAGE"/breeze-core/}" >> "$entries"
  done
  awk -v ins="$entries" '
    /# BEGIN-BUNDLE-TREE/ { skip=1; while ((getline l < ins) > 0) print l; next }
    /# END-BUNDLE-TREE/   { skip=0; next }
    !skip { print }
  ' packaging/nfpm/nfpm.yaml > "$out"
}

if [ "$LIBC" = glibc ]; then FORMATS="deb rpm archlinux"; else FORMATS="apk"; fi
for fmt in $FORMATS; do
  echo "--- nfpm $fmt ($LIBC/$ARCH) ---"
  cfg=packaging/nfpm/nfpm.yaml
  if [ "$fmt" = apk ]; then
    gen_apk_yaml /tmp/nfpm-apk.yaml
    cfg=/tmp/nfpm-apk.yaml
  fi
  nfpm package -f "$cfg" -p "$fmt" -t "$OUT/"
done

# --- tarball (bundle + install.sh + service files) ---------------------------
TDIR="breeze-core-$BC_VERSION-linux-$LIBC-$ARCH"
rm -rf "/tmp/$TDIR"; mkdir -p "/tmp/$TDIR"
cp -R "$STAGE/breeze-core" "/tmp/$TDIR/breeze-core"
install -m 755 packaging/tarball/install.sh "/tmp/$TDIR/install.sh"
install -m 644 packaging/nfpm/breeze-core.service "/tmp/$TDIR/breeze-core.service"
install -m 755 packaging/nfpm/breeze-core.initd "/tmp/$TDIR/breeze-core.initd"
install -m 644 packaging/nfpm/breeze-core.env "/tmp/$TDIR/breeze-core.env"
install -m 644 README.md LICENSE "/tmp/$TDIR/"
tar -C /tmp -czf "$OUT/$TDIR.tar.gz" "$TDIR"
echo "--- tarball $TDIR.tar.gz ---"

ls -la "$OUT" | sed -n "s/.*\($LIBC\|_$ARCH\|$TDIR\).*/  &/p" || true
