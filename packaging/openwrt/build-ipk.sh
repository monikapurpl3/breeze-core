#!/usr/bin/env bash
# Build OpenWrt .ipk packages from the musl bundles.
#
# OpenWrt is musl, so the Alpine-built bundles run as-is on targets with the
# storage for them (~65 MB installed): x86 boxes, RPi/NAS-class ARM64, or any
# router with extroot. opkg matches Architecture EXACTLY, so the same arm64
# payload is emitted under the common aarch64 labels.
#
#   .ipk = tar.gz( debian-binary, control.tar.gz, data.tar.gz ) — built by
#   hand here (nfpm has no ipk support). Output: packaging/out/pkg/*.ipk
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO"
VER="$(sed -n 's/^__version__ = "\(.*\)"/\1/p' meow_ac/__init__.py)"


[ -d packaging/out/bundle-musl-amd64 ] || { echo "musl bundles missing — run build-binaries.sh"; exit 1; }

# Stream the inputs in and the .ipk files out rather than bind-mounting the repo.
# Docker Desktop refuses to mount this checkout at all ("is not shared from the
# host"), and has separately been seen presenting a mount as silently empty --
# which is why packaging/nfpm/build-packages.sh streams as well. The build script
# itself travels inside the tar, so none of it has to survive shell quoting.
mkdir -p packaging/out/pkg
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
cat > "$WORK/build-inside.sh" <<'EOS'
set -eu
VER="$1"
apk add --no-cache bash tar >/dev/null

build_one() { # build_one <bundle-arch: amd64|arm64> <opkg-arch-label>
    barch="$1"; oarch="$2"
    W=/tmp/ipk-$oarch
    rm -rf "$W"; mkdir -p "$W/data/usr/lib" "$W/data/etc/init.d" "$W/data/etc/breeze-core" "$W/ctl"

    # data: bundle (deref symlinks + fix modes lost on the Windows checkout)
    cp -RL "/work/packaging/out/bundle-musl-$barch/breeze-core" "$W/data/usr/lib/breeze-core"
    find "$W/data" -type d -exec chmod 755 {} +
    find "$W/data" -type f -exec chmod 644 {} +
    chmod 755 "$W/data/usr/lib/breeze-core/breeze-core"
    # OpenWrt's base system ships no libz; the bundle carries its own, but the
    # PyInstaller bootloader links it at exec time — point the loader at
    # _internal via a wrapper (keeps the package dependency-free).
    mkdir -p "$W/data/usr/bin"
    cat > "$W/data/usr/bin/breeze-core" <<'EOF'
#!/bin/sh
export LD_LIBRARY_PATH="/usr/lib/breeze-core/_internal${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
exec /usr/lib/breeze-core/breeze-core "$@"
EOF
    chmod 755 "$W/data/usr/bin/breeze-core"
    install -m 755 /work/packaging/openwrt/breeze-core.init "$W/data/etc/init.d/breeze-core"
    install -m 640 /work/packaging/nfpm/breeze-core.env "$W/data/etc/breeze-core/breeze-core.env"
    ISIZE=$(du -sk "$W/data" | cut -f1)

    # control
    cat > "$W/ctl/control" <<EOF
Package: breeze-core
Version: $VER-1
Architecture: $oarch
Maintainer: monikapurpl3 <monikapurpl3@users.noreply.github.com>
Section: utils
Priority: optional
Installed-Size: $((ISIZE * 1024))
Description: Self-hosted, LAN-first control for Midea air conditioners.
 REST API + web control panel; self-contained build, no Python required.
 Needs ~65 MB of storage — x86/ARM64 devices or extroot.
EOF
    echo "/etc/breeze-core/breeze-core.env" > "$W/ctl/conffiles"
    cat > "$W/ctl/postinst" <<'EOF'
#!/bin/sh
grep -q '^breeze:' "${IPKG_INSTROOT}/etc/group"  2>/dev/null || echo 'breeze:x:8420:' >> "${IPKG_INSTROOT}/etc/group"
grep -q '^breeze:' "${IPKG_INSTROOT}/etc/passwd" 2>/dev/null || \
    echo 'breeze:x:8420:8420:breeze:/etc/breeze-core:/bin/false' >> "${IPKG_INSTROOT}/etc/passwd"
[ -n "${IPKG_INSTROOT}" ] || {
    chown -R breeze:breeze /etc/breeze-core 2>/dev/null || true
    chmod 750 /etc/breeze-core; chown root:breeze /etc/breeze-core/breeze-core.env 2>/dev/null || true
    /etc/init.d/breeze-core enable
    echo "breeze-core: pair with 'breeze-core pair', set BREEZE_HOST in /etc/breeze-core/breeze-core.env,"
    echo "breeze-core: then '/etc/init.d/breeze-core start'."
}
exit 0
EOF
    cat > "$W/ctl/prerm" <<'EOF'
#!/bin/sh
[ -n "${IPKG_INSTROOT}" ] || { /etc/init.d/breeze-core stop 2>/dev/null; /etc/init.d/breeze-core disable 2>/dev/null; }
exit 0
EOF
    chmod 755 "$W/ctl/postinst" "$W/ctl/prerm"

    # assemble .ipk
    echo "2.0" > "$W/debian-binary"
    tar -C "$W/ctl"  -czf "$W/control.tar.gz" .
    tar -C "$W/data" -czf "$W/data.tar.gz" .
    OUT="/work/packaging/out/pkg/breeze-core_${VER}-1_${oarch}.ipk"
    tar -C "$W" -czf "$OUT" ./debian-binary ./control.tar.gz ./data.tar.gz
    echo "built $(basename "$OUT")"
}

build_one amd64 x86_64
for a in aarch64_generic aarch64_cortex-a53 aarch64_cortex-a72; do
    build_one arm64 "$a"
done
EOS

tar -cf - packaging/out/bundle-musl-amd64 packaging/out/bundle-musl-arm64 \
        packaging/openwrt/breeze-core.init packaging/nfpm/breeze-core.env \
        -C "$WORK" build-inside.sh \
  | MSYS_NO_PATHCONV=1 docker run -i --rm alpine:3.20 sh -c '
      set -eu
      exec 3>&1 1>&2
      mkdir -p /work && cd /work && tar -xf -
      mkdir -p /work/packaging/out/pkg
      apk add --no-cache bash tar >/dev/null
      sh ./build-inside.sh "'"$VER"'"
      tar -cf - -C /work/packaging/out/pkg . >&3
    ' | tar -xf - -C packaging/out/pkg

ls -la packaging/out/pkg/*.ipk
