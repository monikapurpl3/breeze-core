#!/bin/sh
# Post-install: refresh the service manager and print the quickstart.
set -e

# SELinux (RHEL/Fedora/Alma/Rocky/SUSE-enforcing): /usr/lib gets lib_t, which
# is NOT a domain-transition entrypoint — the service would stay in init_t and
# get silent (dontaudit'd) write denials on /etc/breeze-core (pairing breaks
# with a 500). Label the executable bin_t so systemd transitions it to
# unconfined_service_t like any normal service binary. No-op elsewhere.
if command -v selinuxenabled >/dev/null 2>&1 && selinuxenabled 2>/dev/null; then
    if command -v semanage >/dev/null 2>&1; then
        semanage fcontext -a -t bin_t "/usr/lib/breeze-core/breeze-core" 2>/dev/null \
            || semanage fcontext -m -t bin_t "/usr/lib/breeze-core/breeze-core" 2>/dev/null || true
        restorecon /usr/lib/breeze-core/breeze-core 2>/dev/null || true
    else
        chcon -t bin_t /usr/lib/breeze-core/breeze-core 2>/dev/null || true
    fi
fi

if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
    systemctl daemon-reload >/dev/null 2>&1 || true
    START='sudo systemctl enable --now breeze-core'
elif command -v rc-update >/dev/null 2>&1; then
    START='sudo rc-update add breeze-core default && sudo rc-service breeze-core start'
else
    START='start the breeze-core service with your init system'
fi

# Upgrade vs fresh install: rpm %post passes $1=1 (install), >=2 (upgrade);
# dpkg postinst passes "configure" with the OLD version in $2 on upgrade
# (empty on first install). On an UPGRADE, refresh a running service so the
# new binary takes effect, and skip the quickstart banner.
_upgrade=0
if [ "${1:-}" = "configure" ]; then
    [ -n "${2:-}" ] && _upgrade=1
elif [ "${1:-0}" -ge 2 ] 2>/dev/null; then
    _upgrade=1
fi

if [ "$_upgrade" -eq 1 ]; then
    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        systemctl try-restart breeze-core >/dev/null 2>&1 || true   # restart only if running
    elif command -v rc-service >/dev/null 2>&1; then
        rc-service breeze-core status >/dev/null 2>&1 && \
            rc-service breeze-core restart >/dev/null 2>&1 || true
    fi
    exit 0
fi

cat <<EOF

  Breeze Core installed.

  1. Pair your AC units (writes /etc/breeze-core/config.json):
         sudo breeze-core pair
  2. For direct LAN use, set this machine's LAN IP in
         /etc/breeze-core/breeze-core.env   (BREEZE_HOST=...)
     or keep 127.0.0.1 if a reverse proxy fronts it.
  3. Start it:
         $START

  Then open http://<BREEZE_HOST>:8420 and pair a browser/app.
  Docs: https://github.com/monikapurpl3/breeze-core

EOF
exit 0
