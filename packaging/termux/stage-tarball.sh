#!/usr/bin/env bash
# Wrap a Termux bundle tar (from build-bundle.sh) into the tarball that gets
# published, with notes and a checksum.
#
#   packaging/termux/stage-tarball.sh aarch64 bundle.tar [outdir]
#
# Mirrors stage_tarball() in packaging/binary/build-poc.sh — same versioned
# top-level directory, same root:root ownership, same NOTES.md-inside contract —
# but the input here already has correct POSIX modes, because build-bundle.sh
# tars it up *inside* the container rather than exporting through buildx onto a
# Windows filesystem. Repacking still happens in a container so the published
# artifact is byte-identical regardless of which OS drove the build.
set -euo pipefail

ARCH="${1:?arch (aarch64|x86_64)}"
BUNDLE="${2:?bundle tar from build-bundle.sh}"
OUTDIR="${3:-packaging/out/poc}"
[ -s "$BUNDLE" ] || { echo "bundle tar missing or empty: $BUNDLE" >&2; exit 1; }

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
VER="$(sed -n 's/^__version__ = "\(.*\)"/\1/p' "$REPO/meow_ac/__init__.py")"
COMMIT="$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo unknown)"
NAME="breeze-core-$VER-termux-$ARCH"
mkdir -p "$OUTDIR"
OUTABS="$(cd "$OUTDIR" && pwd)"

notesdir="$(mktemp -d)"; trap 'rm -rf "$notesdir"' EXIT
cat > "$notesdir/NOTES.md" <<NOTES
# Breeze Core $VER for Termux ($ARCH)

Built from commit \`$COMMIT\`, frozen at $VER. **Proof of concept, not a release.**

## What this is

A self-contained bundle that runs **inside Termux** on Android. The frozen binary
ran \`breeze-core version\` on an emulated $ARCH Termux guest during the build,
and the build fails if it does not.

## What this is NOT

- **Not a generic Android binary.** The PyInstaller bootloader carries Termux
  own library path (\`/data/data/com.termux/files/usr/...\`), so it runs under
  Termux and nowhere else on the device. Calling it "bionic-generic" would
  promise more than it delivers.
- **Not the arm64 musl bundle.** Android is Bionic; no glibc or musl build runs
  there, same CPU notwithstanding.
- **Not supported or updated.** No repository, no signature, no upgrade path.

## Running it

\`\`\`sh
tar -xzf $NAME.tar.gz
cd $NAME
./breeze-core version
# Keep Android from suspending it the moment the screen goes off:
termux-wake-lock
AC_CONFIG=./config.json ./breeze-core serve --host 127.0.0.1 --port 8420
\`\`\`

\`breeze-core\` also carries the \`diag\`, \`approve\` and \`setup\`
subcommands. Run it with no arguments for the list. For a supervised service,
\`pkg install termux-services\` and see \`packaging/termux/install.sh\`, which is
the on-device from-source route.

## How it was built, in case you are porting something else

This one is worth reading if you are fighting the same fight. The Rust
dependency (pydantic-core) is **cross-compiled on a workstation**, not built on
the phone or under emulation:

1. \`packaging/termux/probe-target.sh\` asks the target what it accepts, rather
   than guessing. Findings that mattered: Termux pip prefers
   \`cp314-cp314-android_24_arm64_v8a\` (so a natively-tagged Android wheel
   installs directly — no retagging), and Termux ships an \`ndk-sysroot\`
   package, so **no 700 MB Android NDK download is needed**.
2. \`packaging/termux/export-sysroot.sh\` pulls out a cross toolchain: headers
   and crt objects from \`ndk-sysroot\`, \`libpython3.14.so\` from \`python\`,
   and libc/libm/libdl/liblog from \`/system/lib64\` — which ndk-sysroot does
   *not* ship, and whose absence looks like a broken sysroot rather than a
   missing one.
3. \`packaging/termux/cross-wheel.sh\` builds the wheel with host clang in ~55
   seconds. Traps, all of which cost an attempt: \`-isystem\` is not enough
   (clang falls through to host glibc headers and dies on
   \`bits/libc-header-start.h\`) so a real \`--sysroot\` is required; the Android
   driver still asks for \`-lgcc\`, which needs the NDK linker-script shim; and
   maturin needs \`ANDROID_API_LEVEL\` or it fails *after* the whole compile.
4. \`packaging/termux/build-bundle.sh\` then runs only PyInstaller under
   emulation, installing the prebuilt wheel with
   \`--only-binary pydantic-core\` so a tag mismatch fails in seconds instead of
   silently falling back to a source build.

Two more Termux-specific gotchas, both of which produced convincing false
diagnoses: the termux-docker image **discards \`docker -e\` variables** via its
entrypoint (settings are passed as a file in the tar instead), and \`pkg\`
rotates mirrors on every invocation regardless of \`sources.list\` — one run
pulled from six different hosts at a crawl. Use \`apt-get\`.

Full reasoning: \`https://github.com/monikapurpl3/breeze-core/wiki/Proof-of-concept-architectures\`.

Bugs: https://github.com/monikapurpl3/breeze-core/issues
NOTES

echo "==> staging $NAME.tar.gz" >&2
tar -cf - -C "$(dirname "$BUNDLE")" "$(basename "$BUNDLE")" -C "$notesdir" NOTES.md \
  | MSYS_NO_PATHCONV=1 docker run -i --rm -e "NAME=$NAME" \
      -e "BUNDLE=$(basename "$BUNDLE")" alpine:3.19 sh -c '
      set -eu
      exec 3>&1 1>&2
      mkdir -p /w && cd /w && tar -xf -
      mkdir -p x && tar -xf "$BUNDLE" -C x
      mv x/breeze-core "$NAME" && mv NOTES.md "$NAME/NOTES.md"
      # Modes are already correct here (build-bundle.sh tars inside Linux); this
      # only normalises ownership away from the container build user.
      chown -R 0:0 "$NAME"
      tar -czf - "$NAME" >&3
    ' > "$OUTABS/$NAME.tar.gz"

[ -s "$OUTABS/$NAME.tar.gz" ] || { echo "staging produced nothing" >&2; rm -f "$OUTABS/$NAME.tar.gz"; exit 1; }
( cd "$OUTABS" && sha256sum "$NAME.tar.gz" > "$NAME.tar.gz.sha256" )
echo "==> $NAME.tar.gz ($(du -h "$OUTABS/$NAME.tar.gz" | cut -f1))" >&2
