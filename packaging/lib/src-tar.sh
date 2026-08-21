# Shipping parts of the working tree to another machine, without shipping the
# signing keys.
#
# WHY THIS FILE EXISTS
# --------------------
# packaging/repo/keys/ holds the real GPG, apk-RSA, FreeBSD-pkg-RSA and usign
# private keys. They are gitignored and have never been committed, which is why
# "it's not in the repo" felt like enough -- but a `tar -cf - .` of the WORKING
# tree does not care what git thinks, and the OPNsense plugin build shipped the
# whole tree to a build VM. The keys landed in /tmp on three BSD VMs and inside a
# FreeBSD jail, and nothing said so.
#
# A denylist (--exclude=packaging/repo/keys) fixes the instance and not the
# class: the next script that tars the tree starts from `.` again. So:
#
#   1. ALLOWLIST. Name the paths the far end actually needs. Anything not named
#      cannot travel, including files that do not exist yet.
#   2. ASSERT. Check the finished archive and refuse to hand it over if key
#      material is in it. A post-condition cannot be forgotten the way a rule
#      can, and it also catches a key committed somewhere unexpected.
#
# Usage:
#   . packaging/lib/src-tar.sh
#   src_tar_allow /tmp/src.tar.gz meow_ac static packaging/opnsense/files
#
# Or, if a script must build its own archive, at least gate the result:
#   assert_tar_clean /tmp/whatever.tar.gz

# Member names that are a leak by themselves. The keys directory catches all nine
# files whatever their format; the two filename patterns catch a key copied
# somewhere else. Note *.rsa is the PRIVATE half -- the public one is *.rsa.pub.
_SRC_TAR_FORBIDDEN_PATH='packaging/repo/keys/'

# forbidden_names <tarball> -> prints offending members
_src_tar_bad_names() {
    tar -tzf "$1" 2>/dev/null | awk '
        index($0, "packaging/repo/keys/")            { print; next }
        /usign\.sec$/                                { print; next }
        /\.rsa$/                                     { print; next }
        /gpg-private/                                { print; next }
    '
}

# assert_tar_clean <tarball>
# Aborts unless the archive is free of key material.
#
# The content check matches a PEM boundary at the START OF A LINE, not the words
# "PRIVATE KEY" anywhere. That precision is the difference between a guard people
# keep and a guard people delete. Two earlier versions were wrong in the same way,
# one level apart: matching the bare phrase refused packaging/bsd/push-src.sh for
# saying it, and matching the unanchored boundary refused the guard's own source
# for quoting the pattern. A real key's boundary owns its line; a mention never
# does.
#
# The name check is not redundant with it. usign.sec is signify format, not PEM,
# so no content pattern would catch it -- only its name does.
assert_tar_clean() {
    _t="$1"
    _bad="$(_src_tar_bad_names "$_t")"
    if [ -n "$_bad" ]; then
        echo "REFUSING TO SHIP $_t -- key material by name:" >&2
        echo "$_bad" | sed 's/^/    /' >&2
        exit 1
    fi
    # ANCHORED to the start of a line, which is not fussiness: PEM puts the
    # boundary on its own line, while a script quoting the pattern has it in the
    # middle of one. Unanchored, this check matched its own source text and
    # refused to ship the very files implementing it.
    if tar -xzOf "$_t" 2>/dev/null | grep -q -- '^-----BEGIN [A-Z ]*PRIVATE KEY-----'; then
        echo "REFUSING TO SHIP $_t -- a member contains a PEM private key block" >&2
        exit 1
    fi
    echo "  $_t: no key material ($(tar -tzf "$_t" 2>/dev/null | wc -l | tr -d ' ') members)" >&2
}

# src_tar_allow <out.tar.gz> <path> [path...]
# Tars ONLY the named repo-relative paths, then asserts. Run from the repo root.
src_tar_allow() {
    _out="$1"; shift
    [ "$#" -gt 0 ] || { echo "src_tar_allow: no paths given" >&2; exit 1; }
    for _p in "$@"; do
        [ -e "$_p" ] || { echo "src_tar_allow: missing path: $_p" >&2; exit 1; }
    done
    tar -czf "$_out" \
        --exclude='__pycache__' --exclude='*.pyc' --exclude='.venv' \
        --exclude='meow_ac/_commit.txt' \
        "$@"
    assert_tar_clean "$_out"
}
