#!/usr/bin/env bash
# Push the source a BSD build needs to a build host, and nothing else.
#
#   ./packaging/bsd/push-src.sh monika@192.168.122.131 [remote-dir]
#
# WHY THIS EXISTS: the BSD packages are built from source on real BSD hosts, and
# that source used to travel as a hand-rolled `tar -czf - .` typed at the prompt.
# That ships the working tree -- including packaging/repo/keys/, which is
# gitignored but very much present on disk -- and it is how the signing keys ended
# up in /tmp and /home on three build VMs. Use this instead of typing a tar: it is
# an allowlist of the paths packaging/bsd/{install,mkpkg-freebsd,mkpkg-netbsd}.sh
# actually read, and it asserts the archive is free of key material before it
# leaves the machine.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO"

USER_AT="${1:?usage: push-src.sh user@host [remote-dir]}"
DEST="${2:-/home/$(echo "$USER_AT" | cut -d@ -f1)/breeze-core}"

. packaging/lib/src-tar.sh

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# Exactly what the BSD scripts read: the app, the panel, the pairing helper and
# the packaging/rc scripts themselves.
src_tar_allow "$TMP/bc-src.tar.gz" \
    meow_ac static setup_device.py requirements.txt packaging/bsd

echo "==> $USER_AT:$DEST" >&2
ssh -o BatchMode=yes "$USER_AT" "rm -rf '$DEST' && mkdir -p '$DEST'"
# Stream it in rather than leaving a tarball lying around on the far side: a
# leftover archive is a second copy to remember to delete.
ssh -o BatchMode=yes "$USER_AT" "tar -xzf - -C '$DEST'" < "$TMP/bc-src.tar.gz"
ssh -o BatchMode=yes "$USER_AT" "
  echo '  extracted:' \$(find '$DEST' -type f | wc -l | tr -d ' ') 'files'
  # Anchored PEM boundary. Unanchored, or matching the bare phrase, this check
  # flagged this script's own text -- see packaging/lib/src-tar.sh.
  n=\$(grep -rl -- '^-----BEGIN [A-Z ]*PRIVATE KEY-----' '$DEST' 2>/dev/null | wc -l | tr -d ' ')
  echo \"  PEM private keys on the far side: \$n\"
  [ \"\$n\" = 0 ] || exit 1
"
echo "pushed." >&2
