#!/bin/sh
# Stop the service before the files disappear (best-effort).
if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
    systemctl stop breeze-core >/dev/null 2>&1 || true
    systemctl disable breeze-core >/dev/null 2>&1 || true
elif command -v rc-service >/dev/null 2>&1; then
    rc-service breeze-core stop >/dev/null 2>&1 || true
    rc-update del breeze-core default >/dev/null 2>&1 || true
fi
exit 0
