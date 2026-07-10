#!/bin/sh
# Config, device tokens, and programs are deliberately KEPT (an upgrade or
# reinstall picks them straight back up). Tell the user how to purge.
if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
    systemctl daemon-reload >/dev/null 2>&1 || true
fi
if [ -d /etc/breeze-core ]; then
    echo "breeze-core: kept /etc/breeze-core (config + device tokens)." >&2
    echo "breeze-core: delete it manually for a full wipe: rm -rf /etc/breeze-core" >&2
fi
exit 0
