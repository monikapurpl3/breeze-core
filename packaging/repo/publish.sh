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

# Refuse to publish an UNRENDERED template. packaging/repo/index.html is a
# template containing @VERSION@, which build-repo.sh substitutes with sed on its
# way into $OUT. Copying the template straight into $OUT bypasses that and puts
# a page reading "v@VERSION@" on the public site -- which is what happened once,
# and which nothing else here would have caught.
if grep -rl '@[A-Z_]\+@' "$OUT" --include='*.html' >/dev/null 2>&1; then
  echo "PUBLISH ABORTED: unrendered placeholders in $OUT:"
  grep -rn '@[A-Z_]\+@' "$OUT" --include='*.html' | head -5 | sed 's/^/  /'
  echo "  (render with: sed \"s/@VERSION@/\$VER/g\" packaging/repo/index.html > $OUT/index.html)"
  exit 1
fi

# build-repo.sh does its signing inside containers running as root, so parts of
# the tree come back root-owned and mode 600 — including the copied *public*
# keys. Left alone that bites twice: tar can't read them (so the upload aborts
# half-way) and anything that does land is unreadable by the web server (403 on
# breeze-core.asc, i.e. no apt/dnf/pacman user can verify the repo). Normalise
# before shipping, and again after extraction so the served tree is world-readable.
# Refuse to publish a tree that is MISSING sections the landing page links to.
#
# publish.sh uploads the whole tree and swaps `current`, so anything absent
# locally VANISHES from the live site -- there is no merge. That is exactly how
# /android/, /windows/, /winget/ and /src/ came to 404 for a while: a republish
# done to add the /poc/ section shipped a tree that had never staged the others,
# and nothing noticed because the smoke check only tested / and the GPG key.
#
# So: pull every root-relative link out of index.html and check it exists.
missing=""
for link in $(grep -oE 'href="/[^"#]*"' "$OUT/index.html" | sed 's/href="//;s/"$//' | sort -u); do
  target="$OUT${link%/}"
  [ -e "$target" ] || [ -e "$OUT$link" ] || missing="$missing $link"
done
if [ -n "$missing" ]; then
  echo "PUBLISH ABORTED: index.html links to paths that are not in $OUT:"
  for m in $missing; do echo "  $m"; done
  echo "  Re-stage them before publishing. The optional ones need env vars:"
  echo "    ANDROID_APK=... WINDOWS_EXE=... POC_DIR=... ./packaging/repo/build-bsd-repo.sh"
  exit 1
fi

echo "=== normalising ownership/permissions ==="
if [ -n "$(find "$OUT" ! -readable -print -quit 2>/dev/null)" ]; then
  sudo chown -R "$(id -un):$(id -gn)" "$OUT"
fi
chmod -R u+rwX,go+rX "$OUT"

echo "=== publishing to $HOST:$ROOT/releases/$TS ==="
# NOTE: no gzip (-cf, not -czf). The tree is almost entirely already-compressed
# packages (.deb/.rpm/.apk/.pkg.tar.zst/.ipk/.pkg/.tgz), so re-gzipping only
# burns CPU and slows the pipe for ~zero size gain.
#
# `set -o pipefail` matters here: without it a tar that aborts mid-stream still
# lets the remote side swap `current` to a PARTIAL tree.
set -o pipefail
tar -C "$OUT" -cf - . | ssh "$HOST" "
  set -e
  mkdir -p '$ROOT/releases/$TS'
  tar -xf - -C '$ROOT/releases/$TS'
  chmod -R u+rwX,go+rX '$ROOT/releases/$TS'
  # tar restores the SOURCE directory's mtime onto the extracted release dir,
  # so a freshly published release can look older than its predecessors. That
  # bit once: the keep-3 prune below sorted the new release 4th and deleted it
  # out from under the symlink, leaving 'current' dangling and the site 404ing.
  touch '$ROOT/releases/$TS'
  ln -sfn 'releases/$TS' '$ROOT/current.new' && mv -Tf '$ROOT/current.new' '$ROOT/current'
  # Prune by NAME, not mtime: the directories are timestamp-named, so a
  # reverse sort is the reliable ordering and can't be perturbed by tar.
  # Never delete whatever 'current' points at, belt and braces.
  cd '$ROOT/releases'
  keep=\"\$(basename \"\$(readlink '$ROOT/current')\")\"
  ls -1d */ | sed 's#/\$##' | sort -r | tail -n +4 | while read -r d; do
    [ \"\$d\" = \"\$keep\" ] || rm -rf -- \"\$d\"
  done
  # A dangling symlink means a broken site — fail loudly rather than silently.
  test -f '$ROOT/current/index.html' || { echo 'PUBLISH BROKEN: current/index.html missing'; exit 1; }
  echo 'live releases:' && ls -1d */ | sort -r | head -3
" || { echo "PUBLISH FAILED — check '$ROOT/current' on $HOST"; exit 1; }

echo "=== smoke check (best-effort; deploy is already live) ==="
# Bounded + non-fatal: the public endpoint can be slow, and the swap above has
# already happened, so a slow curl must not fail the publish.
for u in / /breeze-core.asc /deb/dists/stable/InRelease; do
  curl -fsS --max-time 20 -o /dev/null -w "$u: %{http_code}\n" \
    "https://bolero.salataputarica.hr.eu.org$u" || echo "$u: (unreachable — check later)"
done
echo "published."
