#!/usr/bin/env bash
# Wrap an OpenWrt wheelhouse into the tarball that gets published, with notes.
#
#   packaging/openwrt/stage-wheelhouse.sh <owrt-arch> <endianness> <wheelhouse> [outdir]
#
#   packaging/openwrt/stage-wheelhouse.sh mips_24kc big \
#       packaging/out/poc/wheelhouse/openwrt-mips_24kc
#
# Wheelhouses are staged per architecture and NEVER merged, for a reason worth
# stating plainly: on 32-bit MIPS the wheel filenames are IDENTICAL across
# endiannesses. `uname -m` reports "mips" on both big- and little-endian, so both
# wheels come out as ...-cp311-cp311-linux_mips.whl with incompatible contents.
# One directory holding both would be a coin flip.
#
# It fails safe rather than silently: the extension module inside carries the full
# multiarch string (mips-linux-muslsf vs mipsel-linux-muslsf), which differs, so
# the wrong-endian wheel installs and then raises ImportError instead of loading
# byte-swapped machine code. Small mercy, but a real one.
set -euo pipefail

OWRT_ARCH="${1:?e.g. mips_24kc}"
ENDIAN="${2:?big|little}"
WHEELDIR="${3:?wheelhouse directory}"
OUTDIR="${4:-packaging/out/poc}"
OWRT_VER="${OWRT_VER:-23.05.5}"

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
VER="$(sed -n 's/^__version__ = "\(.*\)"/\1/p' "$REPO/meow_ac/__init__.py")"
COMMIT="$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo unknown)"
ls "$WHEELDIR"/*.whl >/dev/null 2>&1 || { echo "no wheels in $WHEELDIR" >&2; exit 1; }

NAME="breeze-core-$VER-openwrt-$OWRT_ARCH-wheelhouse"
mkdir -p "$OUTDIR"; OUTABS="$(cd "$OUTDIR" && pwd)"
stage="$(mktemp -d)"; trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/$NAME"
cp "$WHEELDIR"/*.whl "$stage/$NAME/"

SO_NAME="$(cd "$stage/$NAME" && python3 -c "
import glob, zipfile
for w in glob.glob('*.whl'):
    for n in zipfile.ZipFile(w).namelist():
        if n.endswith('.so'):
            print(n.split('/')[-1]); raise SystemExit
" 2>/dev/null || echo unknown)"

cat > "$stage/$NAME/NOTES.md" <<NOTES
# Breeze Core $VER — OpenWrt wheelhouse ($OWRT_ARCH, $ENDIAN-endian)

Built from commit \`$COMMIT\`, frozen at $VER, against the **OpenWrt $OWRT_VER
SDK** for this architecture. **Proof of concept, not a release.**

## What this is, and why it is wheels rather than a bundle

The native Python dependency Breeze Core cannot get from the OpenWrt feed —
\`pydantic-core\`, a Rust extension — cross-compiled for \`$OWRT_ARCH\`.

A frozen PyInstaller bundle would be ~25 MB. Routers have 8–16 MB of flash, so
the bundle is the wrong artifact here; wheels are the right one. Install them
into an extroot, a USB mount or a chroot and you have a working environment for
developing against real hardware. This exists to save you the week described at
the bottom of this file, not to be a plug-and-play product.

## Everything else comes from the OpenWrt feed

\`\`\`sh
opkg update
opkg install python3 python3-pip python3-cryptodome
\`\`\`

\`python3-cryptodome\` is the feed's pycryptodome — msmart-ng needs it, and the
feed build is preferable to anything we could produce. Then:

\`\`\`sh
pip install --find-links . --only-binary pydantic-core pydantic-core
pip install fastapi uvicorn msmart-ng brotli-asgi   # the rest is pure Python
\`\`\`

\`--only-binary pydantic-core\` matters: without it, a tag mismatch silently
falls back to a source build, and compiling Rust on a router is not a thing that
finishes.

## ⚠️ Do not mix this with the other-endian wheelhouse

On 32-bit MIPS the wheel **filenames are identical** across endiannesses —
\`uname -m\` reports \`mips\` for both — so \`...-cp311-cp311-linux_mips.whl\`
from the big-endian and little-endian builds are different files with the same
name. Keep them apart.

If you do get it wrong it fails safely rather than mysteriously: the extension
module inside is named \`$SO_NAME\`, carrying the full multiarch string, so the
wrong one raises \`ImportError\` rather than executing byte-swapped code.

## Verified how

- The extension module is ELF 32/64-bit **$ENDIAN-endian** MIPS, soft-float where
  the ABI calls for it, built by the OpenWrt SDK toolchain.
- Installed and executed on an emulated $OWRT_ARCH userland with **no compiler
  present**, where \`SchemaValidator({"type":"float","ge":16,"le":30})\` accepts
  22.5 and raises \`ValidationError\` for 99.0 — i.e. the Rust code actually runs,
  not merely imports.

## If you are porting something else to OpenWrt

The recipe is \`packaging/openwrt/cross-wheel.sh\` (build) and
\`packaging/openwrt/verify-wheel.sh\` (prove it), and the comments in both are
mostly a record of what went wrong. The short version:

- **Rust MIPS targets are tier 3.** No prebuilt \`std\`, so nightly plus
  \`rust-src\` plus \`-Z build-std\`. Usefully, \`mips*-unknown-linux-musl\`
  already defaults to \`+mips32r2,+soft-float\`, which matches 24kc exactly.
- **The extension suffix does not match what maturin emits.** OpenWrt CPython
  accepts \`.cpython-311-mips-linux-musl**sf**.so\`; maturin produces
  \`...-musl.so\`, which is not in \`importlib.machinery.EXTENSION_SUFFIXES\`.
  The wheel installs cleanly and then fails to import. The \`.so\` is renamed
  inside the wheel.
- **No libpython, and sysconfigdata ships as a \`.pyc\` only** (the \`.py\` is
  stripped to save flash), so pyo3's cross-detection has nothing to parse. Use an
  explicit \`PYO3_CONFIG_FILE\`.
- **\`libc\` is not installable from any feed.** musl is baked into the firmware
  image, so \`Depends: libc\` is satisfied by the base system. To assemble a test
  userland you need the loader from the SDK toolchain.
- **\`python3-light\` is not the stdlib.** OpenWrt splits it up; \`decimal\`,
  which pydantic-core imports at module scope, is a separate package. Install the
  \`python3\` meta-package.
- **maturin's manylinux audit fails on MIPS** — goblin misparses MIPS64 section
  headers and reports a nonsense symbol-table size *after* a successful compile.
  \`--compatibility linux\` skips an audit that is meaningless here anyway.

Full reasoning: \`https://github.com/monikapurpl3/breeze-core/wiki/Proof-of-concept-architectures\`.

Bugs: https://github.com/monikapurpl3/breeze-core/issues
NOTES

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
