#!/bin/sh
# Breeze Core — generic Linux installer for the self-contained tarball.
# For distros without a native package (Void, Gentoo, Slackware, …) or anyone
# who prefers a tarball. Detects systemd / OpenRC / runit and installs the
# matching service; everything else gets clear manual instructions.
#
#   sudo ./install.sh              install (or upgrade in place)
#   sudo ./install.sh --uninstall  remove program + service (keeps /etc/breeze-core)
#
# Layout after install:
#   /usr/lib/breeze-core/   the self-contained bundle (no Python needed)
#   /usr/bin/breeze-core    symlink
#   /etc/breeze-core/       config + tokens + programs (owned by 'breeze')
set -eu

PREFIX="${PREFIX:-/usr}"
LIBDIR="$PREFIX/lib/breeze-core"
BINLINK="$PREFIX/bin/breeze-core"
ETCDIR=/etc/breeze-core
HERE="$(cd "$(dirname "$0")" && pwd)"

say()  { printf '[breeze] %s\n' "$*"; }
die()  { printf '[breeze] ERROR: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "run as root (sudo ./install.sh)"

detect_init() {
    if [ -d /run/systemd/system ]; then echo systemd
    elif command -v rc-update >/dev/null 2>&1; then echo openrc
    elif [ -d /etc/sv ] && command -v sv >/dev/null 2>&1; then echo runit
    else echo none; fi
}

uninstall() {
    case "$(detect_init)" in
        systemd) systemctl stop breeze-core 2>/dev/null || true
                 systemctl disable breeze-core 2>/dev/null || true
                 rm -f /etc/systemd/system/breeze-core.service
                 systemctl daemon-reload 2>/dev/null || true ;;
        openrc)  rc-service breeze-core stop 2>/dev/null || true
                 rc-update del breeze-core default 2>/dev/null || true
                 rm -f /etc/init.d/breeze-core ;;
        runit)   sv down breeze-core 2>/dev/null || true
                 rm -f /var/service/breeze-core /etc/runit/runsvdir/default/breeze-core 2>/dev/null || true
                 rm -rf /etc/sv/breeze-core ;;
    esac
    rm -rf "$LIBDIR"; rm -f "$BINLINK"
    say "removed. Kept $ETCDIR (config + tokens) — delete manually for a full wipe."
    exit 0
}
[ "${1:-}" = "--uninstall" ] && uninstall

[ -d "$HERE/breeze-core" ] || die "bundle dir not found next to install.sh — run from the unpacked tarball"

# --- service user -----------------------------------------------------------
if ! getent group breeze >/dev/null 2>&1; then
    if command -v groupadd >/dev/null 2>&1; then groupadd --system breeze
    else addgroup -S breeze; fi
fi
if ! getent passwd breeze >/dev/null 2>&1; then
    if command -v useradd >/dev/null 2>&1; then
        useradd --system --gid breeze --no-create-home --home-dir "$ETCDIR" --shell /sbin/nologin breeze
    else
        adduser -S -D -H -G breeze -h "$ETCDIR" -s /sbin/nologin breeze
    fi
fi

# --- program ----------------------------------------------------------------
say "installing bundle to $LIBDIR"
rm -rf "$LIBDIR"
mkdir -p "$(dirname "$LIBDIR")"
cp -R "$HERE/breeze-core" "$LIBDIR"
# Normalize without needing find(1) (ultra-minimal systems lack it): dirs
# 755, files keep the tarball's modes; X preserves existing exec bits.
chmod -R u=rwX,go=rX "$LIBDIR"
chmod 755 "$LIBDIR/breeze-core"
ln -sf "$LIBDIR/breeze-core" "$BINLINK"

mkdir -p "$ETCDIR"
[ -f "$ETCDIR/breeze-core.env" ] || cp "$HERE/breeze-core.env" "$ETCDIR/breeze-core.env"
chown breeze:breeze "$ETCDIR"
chmod 750 "$ETCDIR"
chown root:breeze "$ETCDIR/breeze-core.env"; chmod 640 "$ETCDIR/breeze-core.env"

# SELinux: /usr/lib is lib_t (not an entrypoint) — without bin_t the service
# runs as init_t and gets silent write denials on /etc/breeze-core.
if command -v selinuxenabled >/dev/null 2>&1 && selinuxenabled 2>/dev/null; then
    if command -v semanage >/dev/null 2>&1; then
        semanage fcontext -a -t bin_t "$LIBDIR/breeze-core" 2>/dev/null \
            || semanage fcontext -m -t bin_t "$LIBDIR/breeze-core" 2>/dev/null || true
        restorecon "$LIBDIR/breeze-core" 2>/dev/null || true
    else
        chcon -t bin_t "$LIBDIR/breeze-core" 2>/dev/null || true
    fi
fi

"$BINLINK" version || die "installed binary failed to run"

# --- service ----------------------------------------------------------------
INIT="$(detect_init)"
case "$INIT" in
    systemd)
        cp "$HERE/breeze-core.service" /etc/systemd/system/breeze-core.service
        systemctl daemon-reload
        START="sudo systemctl enable --now breeze-core"
        ;;
    openrc)
        cp "$HERE/breeze-core.initd" /etc/init.d/breeze-core
        chmod 755 /etc/init.d/breeze-core
        START="sudo rc-update add breeze-core default && sudo rc-service breeze-core start"
        ;;
    runit)
        mkdir -p /etc/sv/breeze-core
        cat > /etc/sv/breeze-core/run <<'EOF'
#!/bin/sh
BREEZE_HOST=127.0.0.1; BREEZE_PORT=8420; BREEZE_OPTS=""
[ -r /etc/breeze-core/breeze-core.env ] && . /etc/breeze-core/breeze-core.env
export AC_CONFIG=/etc/breeze-core/config.json
export AC_DEVICES=/etc/breeze-core/devices.json
export AC_PROGRAMS=/etc/breeze-core/programs.json
exec chpst -u breeze:breeze /usr/lib/breeze-core/breeze-core \
    serve --host "$BREEZE_HOST" --port "$BREEZE_PORT" $BREEZE_OPTS 2>&1
EOF
        chmod 755 /etc/sv/breeze-core/run
        SVDIR=/var/service; [ -d /etc/runit/runsvdir/default ] && SVDIR=/etc/runit/runsvdir/default
        START="sudo ln -s /etc/sv/breeze-core $SVDIR/"
        ;;
    *)
        START="wire $LIBDIR/breeze-core serve into your init (templates: deploy/init/ in the repo)"
        ;;
esac

cat <<EOF

  Breeze Core installed ($INIT).

  1. Pair your AC units:      sudo breeze-core pair
  2. Set your LAN IP in       $ETCDIR/breeze-core.env   (BREEZE_HOST=...)
  3. Start the service:       $START

  Then open http://<BREEZE_HOST>:8420. Docs: https://github.com/monikapurpl3/breeze-core
EOF
