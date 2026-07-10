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
