#!/bin/sh
# Build a native FreeBSD .pkg from an already-installed tree (run AFTER
# packaging/bsd/install.sh, on FreeBSD). Stages the installed files, writes a
# manifest + plist, and runs pkg-create(8). The venv bakes in absolute paths,
# so the package is prefix-fixed to /usr/local (as FreeBSD packages are).
#
#   sh packaging/bsd/mkpkg-freebsd.sh [output-dir]
set -eu

OUT="${1:-.}"
VER="$(sed -n 's/^__version__ = "\(.*\)"/\1/p' meow_ac/__init__.py)"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

# Copy the installed files into a package root.
mkdir -p "$STAGE/usr/local/bin" "$STAGE/usr/local/etc/rc.d"
cp -R /usr/local/breeze-core "$STAGE/usr/local/breeze-core"
cp /usr/local/bin/breeze-core "$STAGE/usr/local/bin/breeze-core"
cp /usr/local/etc/rc.d/breeze_core "$STAGE/usr/local/etc/rc.d/breeze_core"

# plist: every staged file/symlink, as absolute paths.
plist="$STAGE/.plist"
( cd "$STAGE" && find usr -type f -o -type l | sed 's#^#/#' ) | sort > "$plist"

# Runtime dep is whatever Python the venv was built against (its interpreter
# is referenced from the venv, so the matching lang/pythonNNN must be present).
PYVER="$(/usr/local/breeze-core/venv/bin/python -c 'import sys;print("%d%d"%sys.version_info[:2])')"

# manifest — UCL format (pkg-create(8)); NOT YAML. desc is one quoted line.
manifest="$STAGE/.manifest"
cat > "$manifest" <<EOF
name = "breeze-core";
version = "$VER";
origin = "comms/breeze-core";
comment = "LAN-first REST API + web UI for Midea air conditioners";
maintainer = "monikapurpl3@users.noreply.github.com";
www = "https://github.com/monikapurpl3/breeze-core";
prefix = "/";
desc = "Self-hosted, LAN-first control for Midea air conditioners - REST API, web control panel and diagnostic CLI, built from source into a private venv. Provides the breeze_core rc.d service.";
deps {
  python${PYVER} {
    origin = "lang/python${PYVER}";
  }
}
EOF

pkg create -o "$OUT" -r "$STAGE" -M "$manifest" -p "$plist"
echo "built: $OUT/breeze-core-$VER.pkg"
