#!/usr/bin/env bash
# Proof-of-concept bundles for architectures outside the supported set:
# s390x, ppc64le, mips64le. Frozen at a tag (v3.0.5 as shipped) — these are
# "it runs" demonstrations, not release artifacts, and nothing else in the
# packaging pipeline knows about them.
#
#   ./packaging/binary/build-poc.sh                 # every target, in turn
#   ./packaging/binary/build-poc.sh s390x           # just one
#   POC_JOBS=8 ./packaging/binary/build-poc.sh      # be gentler still
#
# ── Why this is strictly sequential ──────────────────────────────────────────
# Every one of these runs under QEMU user-mode emulation, where each compile
# job is a separate emulated, single-threaded process. Two builds at
# `-j$(nproc)` each therefore put ~2x the thread count of emulated processes on
# the CPU: the machine thrashes, the desktop stutters, and *both* builds finish
# later than if they had been run one after the other. Learned the hard way.
# One build at a time, and not even that one gets every core.
set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"; cd "$REPO"

# Half the machine by default, leaving the other half for whoever is using it.
NPROC="$(nproc 2>/dev/null || echo 4)"
JOBS="${POC_JOBS:-$(( NPROC / 2 ))}"
[ "$JOBS" -lt 2 ] && JOBS=2

OUT="packaging/out/poc"
LOGS="$OUT/logs"
mkdir -p "$LOGS"
COMMIT="$(git rev-parse --short HEAD)"
VER="$(sed -n 's/^__version__ = "\(.*\)"/\1/p' meow_ac/__init__.py)"

# musl targets, built from Dockerfile.musl on alpine:edge.
#
# edge and not 3.19 for the same reason riscv64 needs it: neither s390x nor
# ppc64le has musllinux wheels for pydantic-core, so it compiles from source,
# and that needs cargo >= 1.85 (edition 2024) plus rustc >= 1.88. Alpine 3.19
# ships rust 1.76 and fails an hour into the build. The OpenWrt musl-1.2.4
# floor that pins the *supported* musl bundles to 3.19 is irrelevant here.
ALL_MUSL="s390x ppc64le"

usage() { echo "targets: $ALL_MUSL mips64le  (default: all)"; }

# Don't test for the execute bit. buildx exports to the host filesystem, and on
# Windows that filesystem carries no POSIX modes — so a bundle that built fine
# and printed its own version during the build still shows up as -rw-r--r--,
# and `[ -x ]` reports a false failure. Size is the honest check here; the
# Dockerfile already ran `breeze-core version` inside the container, which is
# the real proof it works on the target architecture.
built_ok() {
  [ -s "$1/breeze-core/breeze-core" ] || return 1
  # A truncated or empty export would still be a file; the real bundle is MBs.
  [ "$(wc -c < "$1/breeze-core/breeze-core")" -gt 1000000 ]
}

build_musl() {
  local arch="$1"
  local dest="$OUT/bundle-musl-$arch" log="$LOGS/$arch.log"
  if built_ok "$dest"; then
    echo "  $arch: already built, skipping (rm -rf $dest to redo)"
    return 0
  fi
  echo "  $arch: building with -j$JOBS on $NPROC threads — see $log"
  local start=$SECONDS
  MSYS_NO_PATHCONV=1 docker buildx build --platform "linux/$arch" \
    -f packaging/binary/Dockerfile.musl \
    --build-arg AC_COMMIT="$COMMIT" \
    --build-arg ALPINE_TAG=edge \
    --build-arg WITH_TOOLCHAIN=1 \
    --build-arg BUILD_JOBS="$JOBS" \
    -o "type=local,dest=$dest" . > "$log" 2>&1
  local rc=$? mins=$(( (SECONDS - start) / 60 ))
  if [ $rc -eq 0 ] && built_ok "$dest"; then
    echo "  $arch: done in ${mins}m"
  else
    echo "  $arch: FAILED after ${mins}m — tail of $log:"
    tail -5 "$log" | sed 's/^/      /'
    return 1
  fi
}

build_mips64le() {
  local dest="$OUT/bundle-glibc-mips64le" log="$LOGS/mips64le.log"
  if built_ok "$dest"; then
    echo "  mips64le: already built, skipping"
    return 0
  fi
  # glibc, not musl: Alpine has no MIPS port at all, so the only usable base is
  # Debian's mips64el port. Also 64-bit only — the binfmt set covers mips64 and
  # mips64le, not 32-bit mips/mipsel, which is what most small routers are.
  echo "  mips64le: building with -j$JOBS — see $log"
  local start=$SECONDS
  MSYS_NO_PATHCONV=1 docker buildx build --platform linux/mips64le \
    -f packaging/binary/Dockerfile.mips \
    --build-arg AC_COMMIT="$COMMIT" \
    --build-arg BUILD_JOBS="$JOBS" \
    -o "type=local,dest=$dest" . > "$log" 2>&1
  local rc=$? mins=$(( (SECONDS - start) / 60 ))
  if [ $rc -eq 0 ] && built_ok "$dest"; then
    echo "  mips64le: done in ${mins}m"
  else
    echo "  mips64le: FAILED after ${mins}m — tail of $log:"
    tail -5 "$log" | sed 's/^/      /'
    return 1
  fi
}

# Turn an exported bundle directory into the tarball that actually gets
# published — and fix, in the process, the two things a raw buildx export gets
# wrong on this host.
#
# 1. MODES. buildx writes to the host filesystem, and on Windows that carries no
#    POSIX modes, so the entry point lands as -rw-r--r--. Tar faithfully records
#    that, and the user's very first act after extracting is "Permission denied"
#    on a binary that is in fact perfectly good. (Same root cause as built_ok()
#    above not testing for -x.)
# 2. LAYOUT. The export nests as bundle-musl-<arch>/breeze-core/breeze-core, so
#    extracting dumps a directory named after our build tree rather than after
#    the release. One versioned top-level directory is what people expect.
#
# Both are fixed inside a throwaway Linux container rather than on the host: the
# modes are real there, and the resulting tarball is then identical no matter
# which OS drove the build. Streamed over stdin/stdout on purpose — Docker
# Desktop bind mounts on this machine sometimes present as silently empty, which
# is the same reason packaging/nfpm/build-packages.sh streams.
stage_tarball() {
  local arch="$1" libc="$2" dest="$3"
  local name="breeze-core-$VER-linux-$libc-$arch"
  local tgz="$OUT/$name.tar.gz"
  if [ -s "$tgz" ]; then
    echo "  $arch: tarball already staged ($(du -h "$tgz" | cut -f1))"
    return 0
  fi
  local notesdir; notesdir="$(mktemp -d)"
  poc_notes "$arch" "$libc" > "$notesdir/NOTES.md"
  # One tar, two source directories: the bundle, then the notes beside it. (Two
  # -C flags in one invocation, rather than concatenating archives — tar applies
  # them in order and the members land at the top level either way.)
  tar -cf - -C "$dest" breeze-core -C "$notesdir" NOTES.md \
    | MSYS_NO_PATHCONV=1 docker run -i --rm -e "NAME=$name" alpine:3.19 sh -c '
        set -eu
        exec 3>&1 1>&2
        mkdir -p /w && cd /w && tar -xf -
        mv breeze-core "$NAME" && mv NOTES.md "$NAME/NOTES.md"
        # The freeze step built these; restore what the export dropped.
        chmod 755 "$NAME/breeze-core"
        find "$NAME" -type d -exec chmod 755 {} +
        find "$NAME" -type f -name "*.so*" -exec chmod 755 {} +
        # Nobody wants a tarball full of uid 197609 from a Windows host. Alpine
        # ships BusyBox tar, which has no --owner/--group, so chown instead —
        # we are root in here, and tar then records what it finds.
        chown -R 0:0 "$NAME"
        tar -czf - "$NAME" >&3
      ' > "$tgz"
  rm -rf "$notesdir"
  if [ ! -s "$tgz" ]; then
    echo "  $arch: staging FAILED — no tarball written"
    rm -f "$tgz"; return 1
  fi
  ( cd "$OUT" && sha256sum "$name.tar.gz" > "$name.tar.gz.sha256" )
  echo "  $arch: staged $name.tar.gz ($(du -h "$tgz" | cut -f1))"
}

# What ships inside every PoC tarball. These bundles are explicitly not
# plug-and-play products — they exist to save a developer on an odd
# architecture the day it takes to discover the same traps we already hit — so
# the notes say what it is, what it is not, and where the sharp edges are.
poc_notes() {
  local arch="$1" libc="$2"
  cat <<NOTES
# Breeze Core $VER — proof-of-concept bundle ($libc/$arch)

Built from commit \`$COMMIT\`, frozen at $VER. **Not a release artifact.**

## What this is

A self-contained PyInstaller bundle for **linux-$libc-$arch**, an architecture
outside Breeze Core's supported set. It was cross-checked the only way that
means anything: the frozen binary ran \`breeze-core version\` on an emulated
$arch guest during the build, and the build fails if that step does not print.

## What this is not

- **Not supported, not updated.** No package repository, no signature, no
  upgrade path. It will not track future releases.
- **Not a system install.** No systemd unit, no service account, no
  \`/etc/breeze-core\`. See \`docs/INSTALL.md\` for what a real deployment does.
- **Not performance-tested** on this architecture.

## Running it

\`\`\`sh
tar -xzf breeze-core-$VER-linux-$libc-$arch.tar.gz
cd breeze-core-$VER-linux-$libc-$arch
./breeze-core version
AC_CONFIG=./config.json ./breeze-core serve --host 127.0.0.1 --port 8420
\`\`\`

\`breeze-core\` carries the diagnostic and approval CLIs too — \`diag\`,
\`approve\`, \`setup\`. Run it with no arguments for the list.

## If you are porting this yourself

The build recipe is \`packaging/binary/Dockerfile.musl\` plus
\`packaging/binary/build-poc.sh\` in the repository, and the comments in both
are mostly a record of what went wrong. The short version, for $arch:

- PyInstaller ships **no bootloader** for this triple, and its sdist will not
  build one for you — waf has to be run explicitly, and with the configure step
  (\`waf distclean all\`; plain \`waf all\` exits successfully in milliseconds
  having compiled nothing).
- Under emulation, **gcc is the unreliable part**, not the code: it died in
  \`cc1\` on s390x and in \`collect2\` on ppc64le. clang got through both.
  Setting \`CC\` alone is not enough — \`LDSHARED\` drives setuptools' link step
  and \`RUSTFLAGS -C linker\` drives rustc's, which otherwise calls plain \`cc\`.
- \`docs/POC-CROSS-BUILDS.md\` argues that all of the above is better solved by
  cross-building the native wheels on the host instead. If you are starting
  fresh, start there.

Bugs, including "it does not run on my $arch box":
https://github.com/monikapurpl3/breeze-core/issues
NOTES
}

TARGETS=("$@")
[ ${#TARGETS[@]} -eq 0 ] && TARGETS=($ALL_MUSL mips64le)

echo "proof-of-concept bundles for $VER ($COMMIT), one at a time"
for t in "${TARGETS[@]}"; do
  case "$t" in
    # build_musl returns 0 for an already-built bundle, so re-running this
    # script stages a tarball for a bundle from an earlier session without
    # rebuilding it.
    s390x|ppc64le) build_musl "$t" && stage_tarball "$t" musl "$OUT/bundle-musl-$t" ;;
    mips64le)      build_mips64le && stage_tarball mips64le glibc "$OUT/bundle-glibc-mips64le" ;;
    -h|--help)     usage; exit 0 ;;
    *)             echo "  unknown target: $t"; usage; exit 1 ;;
  esac
done

echo ""
echo "== $OUT =="
for d in "$OUT"/bundle-*/; do
  [ -d "$d" ] || continue
  b="$d/breeze-core/breeze-core"
  [ -s "$b" ] && echo "  $(basename "$d"): $(du -sh "$d" | cut -f1)"
done
echo ""
echo "== publishable tarballs (POC_DIR for packaging/repo/build-bsd-repo.sh) =="
found=0
for t in "$OUT"/*.tar.gz; do
  [ -s "$t" ] || continue
  found=1
  echo "  $(basename "$t")  $(du -h "$t" | cut -f1)"
done
[ "$found" = 0 ] && echo "  (none yet)"
