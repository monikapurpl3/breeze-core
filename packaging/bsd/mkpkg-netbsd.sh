#!/bin/sh
# Build a native NetBSD binary package (.tgz) from an already-installed tree
# (run AFTER packaging/bsd/install.sh, on NetBSD). Uses pkg_create(1) from the
# base system. The venv bakes in absolute /usr/pkg paths, so the package is
# fixed to the /usr/pkg prefix (as pkgsrc packages are); it depends on
# python312 (the interpreter the venv was built against).
#
# pkg_create reads the packing-list files from the @cwd prefix (the real
# /usr/pkg), so everything packaged must live there. The app, venv and wrapper
# already do; the rc.d script (install.sh puts it in /etc/rc.d, outside the
# prefix) is copied to ${PREFIX}/share/examples/rc.d and an @exec wires it into
# /etc/rc.d at install time.
#
#   sh packaging/bsd/mkpkg-netbsd.sh [output-dir]
set -eu

OUT="${1:-.}"
VER="$(sed -n 's/^__version__ = "\(.*\)"/\1/p' meow_ac/__init__.py)"
PREFIX=/usr/pkg
META="$(mktemp -d)"
trap 'rm -rf "$META"' EXIT

# Ship the rc.d script as a pkgsrc example under the prefix so it can be
# packaged (an @exec copies it into /etc/rc.d at install).
mkdir -p "$PREFIX/share/examples/rc.d"
cp /etc/rc.d/breeze_core "$PREFIX/share/examples/rc.d/breeze_core"

printf 'LAN-first REST API + web UI for Midea air conditioners\n' > "$META/COMMENT"
cat > "$META/DESC" <<'EOF'
Breeze Core - self-hosted, LAN-first control for Midea air conditioners.
REST API, web control panel and diagnostic CLI, built from source into a
private virtualenv. Provides the breeze_core rc.d service (installed to
/etc/rc.d; enable with breeze_core=YES in /etc/rc.conf).
EOF

# INSTALL script: create the unprivileged service user + config dir before the
# files land, and hand ownership over afterwards.
cat > "$META/INSTALL" <<'EOF'
#!/bin/sh
case "$2" in
PRE-INSTALL)
	id breeze >/dev/null 2>&1 || \
	  useradd -c "Breeze Core service" -d /nonexistent -s /sbin/nologin breeze 2>/dev/null || true
	mkdir -p /usr/pkg/etc/breeze-core
	;;
POST-INSTALL)
	chown -R breeze /usr/pkg/breeze-core /usr/pkg/etc/breeze-core 2>/dev/null || true
	;;
esac
exit 0
EOF

# Build-info so pkg_add sees a matching OS/ABI (else it refuses the package).
# (We deliberately don't set PKGTOOLS_VERSION: pkg_add only prints a harmless
# "lacks pkg_install version data" note, whereas a value that doesn't match the
# host's exact pkg_install release makes pkg_add reject the package outright.)
cat > "$META/BUILD_INFO" <<EOF
OPSYS=$(uname -s)
OS_VERSION=$(uname -r)
MACHINE_ARCH=$(uname -p)
EOF

# Packing list: prefix, python dep, every installed file/symlink (relative to
# the prefix), then the rc.d wiring.
plist="$META/PLIST"
{
	echo "@cwd $PREFIX"
	echo "@pkgdep python312>=3.12"
	echo "bin/breeze-core"
	( cd "$PREFIX" && find breeze-core share/examples/rc.d/breeze_core \( -type f -o -type l \) | sort )
	echo "@exec [ -d /etc/rc.d ] && cp -f %D/share/examples/rc.d/breeze_core /etc/rc.d/breeze_core && chmod 755 /etc/rc.d/breeze_core"
	echo "@unexec rm -f /etc/rc.d/breeze_core"
} > "$plist"

# pkg_create writes the package under exactly the name given (it does NOT
# append a suffix — pkgsrc passes the full .tgz filename), so name it directly.
mkdir -p "$OUT"
pkg_create \
	-c "$META/COMMENT" \
	-d "$META/DESC" \
	-i "$META/INSTALL" \
	-f "$plist" \
	-B "$META/BUILD_INFO" \
	"$OUT/breeze-core-$VER.tgz"

ls -la "$OUT/breeze-core-$VER.tgz"
echo "built: $OUT/breeze-core-$VER.tgz"
