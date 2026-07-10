#!/bin/sh
# Post-install: refresh the service manager and print the quickstart.
set -e

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
