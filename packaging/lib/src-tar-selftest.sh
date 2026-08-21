#!/usr/bin/env bash
# Self-test for the leak guard in src-tar.sh.
#
#   sh packaging/lib/src-tar-selftest.sh
#
# Exercises it against key material in the shapes that actually exist here --
# PEM (gpg/apk/pkg keys) and signify (usign.sec, which no content pattern can
# match) -- and against prose that merely mentions private keys, which an earlier
# version of the guard wrongly rejected. Uses synthetic keys; it never copies the
# real ones anywhere.
set -uo pipefail
cd "$(cd "$(dirname "$0")/../.." && pwd)"
. packaging/lib/src-tar.sh

W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
pass=0; fail=0
check() { # check <expect: ok|refuse> <name> <tarball>
    if ( assert_tar_clean "$3" ) >/dev/null 2>&1; then got=ok; else got=refuse; fi
    if [ "$got" = "$1" ]; then pass=$((pass+1)); echo "  PASS  $2 ($got)"
    else fail=$((fail+1)); echo "  FAIL  $2 (expected $1, got $got)"; fi
}

# 1. Clean source: the real allowlist the BSD push uses.
tar -czf "$W/clean.tgz" meow_ac static setup_device.py requirements.txt
check ok "clean source passes" "$W/clean.tgz"

# 2. A PEM private key, at a path with an innocent name.
mkdir -p "$W/s/config"
{ echo "-----BEGIN PRIVATE KEY-----"; echo "bm90IGEgcmVhbCBrZXk="; echo "-----END PRIVATE KEY-----"; } \
    > "$W/s/config/settings.conf"
tar -czf "$W/pem.tgz" -C "$W/s" config
check refuse "PEM key under an innocent name is caught by content" "$W/pem.tgz"

# 3. usign.sec: signify format, no PEM markers -- only the name can catch it.
mkdir -p "$W/u/packaging/repo/keys"
printf 'untrusted comment: signify secret key\nRWRCS3lu%s\n' "bm90cmVhbA==" \
    > "$W/u/packaging/repo/keys/usign.sec"
tar -czf "$W/usign.tgz" -C "$W/u" packaging
check refuse "usign.sec is caught by name, not content" "$W/usign.tgz"

# 3b. Same file, moved out of the keys directory: the filename rule still holds.
mkdir -p "$W/u2/etc"
cp "$W/u/packaging/repo/keys/usign.sec" "$W/u2/etc/usign.sec"
tar -czf "$W/usign2.tgz" -C "$W/u2" etc
check refuse "usign.sec outside the keys dir is still caught" "$W/usign2.tgz"

# 4. The private half of an apk/pkg RSA key, by extension.
mkdir -p "$W/r/x"
echo "whatever" > "$W/r/x/breeze-core@bolero.rsa"
tar -czf "$W/rsa.tgz" -C "$W/r" x
check refuse "*.rsa (the private half) is caught" "$W/rsa.tgz"

# 4b. ...but its public counterpart must NOT be, or every repo build breaks.
mkdir -p "$W/rp/x"
echo "whatever" > "$W/rp/x/breeze-core@bolero.rsa.pub"
tar -czf "$W/rsapub.tgz" -C "$W/rp" x
check ok "*.rsa.pub (public) is allowed through" "$W/rsapub.tgz"

# 5. No false positive on prose. This is why the guard matches the PEM boundary
#    and not the bare phrase: it used to reject push-src.sh for saying it.
mkdir -p "$W/p/packaging/bsd"
cat > "$W/p/packaging/bsd/push-src.sh" <<'INNER'
# check the far side for leaks
grep -rl 'PRIVATE KEY' "$DEST" && exit 1
INNER
tar -czf "$W/prose.tgz" -C "$W/p" packaging
check ok "a script that mentions PRIVATE KEY is not rejected" "$W/prose.tgz"

# 6. The guard's own source must survive being scanned. Both earlier versions
#    failed here: one matched the phrase "PRIVATE KEY", the next matched an
#    unanchored PEM boundary, and each rejected the files implementing it.
mkdir -p "$W/self/packaging/lib" "$W/self/packaging/bsd"
cp packaging/lib/src-tar.sh packaging/lib/src-tar-selftest.sh "$W/self/packaging/lib/"
cp packaging/bsd/push-src.sh "$W/self/packaging/bsd/"
tar -czf "$W/self.tgz" -C "$W/self" packaging
check ok "the guard's own source is not a false positive" "$W/self.tgz"

# 7. A boundary that is genuinely mid-line is not a PEM file, and must not trip it.
mkdir -p "$W/mid"
echo 'the marker -----BEGIN PRIVATE KEY----- appears mid-sentence here' > "$W/mid/notes.txt"
tar -czf "$W/mid.tgz" -C "$W/mid" notes.txt
check ok "a mid-line boundary in prose is not treated as a key" "$W/mid.tgz"

echo
echo "  $pass passed, $fail failed"
[ "$fail" = 0 ]
