#!/usr/bin/env bash
# Wrap any wheelhouse into a publishable tarball with a supplied NOTES.md.
#
#   packaging/binary/stage-wheelhouse.sh <name-suffix> <notes-file> <wheeldir> [outdir]
#
#   packaging/binary/stage-wheelhouse.sh linux-glibc-mips64el-wheelhouse \
#       /tmp/notes.md packaging/out/poc/wheelhouse/mips64le
#
# The generic sibling of packaging/openwrt/stage-wheelhouse.sh, which generates
# its own OpenWrt-specific notes. This one takes the notes as a file, because the
# remaining wheelhouses need to say quite different things: one is a by-product of
# debugging the toolchain, the other ships unverified and has to say so loudly.
#
# Repacking happens in a container so ownership and modes are real regardless of
# the host OS — same reasoning as the bundle stager in build-poc.sh.
set -euo pipefail

SUFFIX="${1:?name suffix, e.g. linux-glibc-mips64el-wheelhouse}"
NOTES="${2:?path to a NOTES.md}"
WHEELDIR="${3:?wheelhouse directory}"
OUTDIR="${4:-packaging/out/poc}"

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
VER="$(sed -n 's/^__version__ = "\(.*\)"/\1/p' "$REPO/meow_ac/__init__.py")"
[ -f "$NOTES" ] || { echo "no notes file at $NOTES" >&2; exit 1; }
ls "$WHEELDIR"/*.whl >/dev/null 2>&1 || { echo "no wheels in $WHEELDIR" >&2; exit 1; }

NAME="breeze-core-$VER-$SUFFIX"
mkdir -p "$OUTDIR"; OUTABS="$(cd "$OUTDIR" && pwd)"
stage="$(mktemp -d)"; trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/$NAME"
cp "$WHEELDIR"/*.whl "$stage/$NAME/"
cp "$NOTES" "$stage/$NAME/NOTES.md"

echo "==> staging $NAME.tar.gz" >&2
tar -cf - -C "$stage" "$NAME" | MSYS_NO_PATHCONV=1 docker run -i --rm \
    -e "NAME=$NAME" alpine:3.19 sh -c '
      set -eu
      exec 3>&1 1>&2
      mkdir -p /w && cd /w && tar -xf -
      chown -R 0:0 "$NAME"
      find "$NAME" -type d -exec chmod 755 {} +
      find "$NAME" -type f -exec chmod 644 {} +
      tar -czf - "$NAME" >&3
    ' > "$OUTABS/$NAME.tar.gz"

[ -s "$OUTABS/$NAME.tar.gz" ] || { echo "staging produced nothing" >&2; rm -f "$OUTABS/$NAME.tar.gz"; exit 1; }
( cd "$OUTABS" && sha256sum "$NAME.tar.gz" > "$NAME.tar.gz.sha256" )
echo "==> $NAME.tar.gz ($(du -h "$OUTABS/$NAME.tar.gz" | cut -f1))" >&2
