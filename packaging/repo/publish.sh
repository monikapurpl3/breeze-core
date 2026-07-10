#!/usr/bin/env bash
# Publish packaging/out/repo/ to the package host (static files only).
# Uploads to a timestamped release dir and atomically swaps the `current`
# symlink nginx serves, keeping the last 3 releases for instant rollback.
# Needs plain ssh access; no sudo (the web root is owned by the push user).
#
#   ./packaging/repo/publish.sh            # push to the default host
#   REPO_HOST=myhost ./packaging/repo/publish.sh
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO"
HOST="${REPO_HOST:-mrrp}"
ROOT="${REPO_ROOT:-/var/www/bolero}"
OUT="packaging/out/repo"
TS="$(date +%Y%m%d-%H%M%S)"

[ -f "$OUT/index.html" ] || { echo "no repo tree — run build-repo.sh first"; exit 1; }

echo "=== publishing to $HOST:$ROOT/releases/$TS ==="
tar -C "$OUT" -czf - . | ssh "$HOST" "
  set -e
  mkdir -p '$ROOT/releases/$TS'
  tar -xzf - -C '$ROOT/releases/$TS'
  ln -sfn 'releases/$TS' '$ROOT/current.new' && mv -Tf '$ROOT/current.new' '$ROOT/current'
  cd '$ROOT/releases' && ls -1dt */ | tail -n +4 | xargs -r rm -rf
  echo 'live releases:' && ls -1dt '$ROOT/releases'/*/ | head -3
"

echo "=== smoke check ==="
curl -fsS -o /dev/null -w "index: %{http_code}\n"      https://bolero.salataputarica.hr.eu.org/
curl -fsS -o /dev/null -w "gpg key: %{http_code}\n"    https://bolero.salataputarica.hr.eu.org/breeze-core.asc
curl -fsS -o /dev/null -w "InRelease: %{http_code}\n"  https://bolero.salataputarica.hr.eu.org/deb/dists/stable/InRelease
echo "published."
