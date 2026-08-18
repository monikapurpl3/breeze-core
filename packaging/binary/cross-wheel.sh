#!/usr/bin/env bash
# Cross-build native wheels for a glibc target on the host, at native speed.
#
#   packaging/binary/cross-wheel.sh <rust-target> <gcc-triple> <deb-arch> \
#                                   <py-minor> <plat-tags> <outdir>
#
#   packaging/binary/cross-wheel.sh mips64el-unknown-linux-gnuabi64 \
#       mips64el-linux-gnuabi64 mips64el 3.11 linux_mips64 \
#       packaging/out/poc/wheelhouse/mips64le
#
# The Debian-target sibling of packaging/termux/cross-wheel.sh. See
# docs/POC-CROSS-BUILDS.md; this is step 2 of §5.
#
# ── Why MIPS cannot be done any other way ───────────────────────────────────
# Not merely slow — impossible in-place. Debian bookworm on mips64el ships
# rustc 1.63; pydantic-core needs >= 1.88. There is no version of "just compile
# it on the target" that works, emulated or otherwise.
#
# ── Two things MIPS needs that Android did not ──────────────────────────────
# 1. -Z build-std. Every MIPS Linux target is Rust TIER 3, so there is no
#    prebuilt std to download — it is compiled from source here, which is why
#    nightly and the rust-src component are required. aarch64-linux-android is
#    tier 2 and needed none of this.
# 2. A retag. The target pip advertises linux_mips64 (uname -m says "mips64"
#    even though the ABI is mips64EL and little-endian), while maturin names the
#    wheel after the Rust target. A wheel tagged linux_mips64el is simply
#    invisible to pip — "no matching distribution", much later and far from the
#    cause.
#
# ── The local optimisation this leans on ────────────────────────────────────
# mips64el and mipsel are *release* Debian architectures, so the target Python
# headers and libpython come straight from deb.debian.org via multiarch on a
# NATIVE container. No emulated container has to be stood up to harvest a
# sysroot the way the Termux build had to, and gcc-<triple> brings its own
# glibc. Host and target Python are both 3.11 on bookworm, so the ABI matches
# for free.
set -euo pipefail

RUST_TARGET="${1:?rust target triple}"
GCC_TRIPLE="${2:?gcc cross triple}"
DEB_ARCH="${3:?debian arch}"
PY_MINOR="${4:?target python minor, e.g. 3.11}"
PLAT_TAGS="${5:?comma-separated platform tags the target pip accepts}"
OUTDIR="${6:?output wheelhouse dir}"
SUITE="${SUITE:-bookworm}"

mkdir -p "$OUTDIR"; OUTABS="$(cd "$OUTDIR" && pwd)"
echo "==> cross-building for $RUST_TARGET (deb:$DEB_ARCH), CPython $PY_MINOR" >&2
echo "==> tags: $PLAT_TAGS -> $OUTABS" >&2

MSYS_NO_PATHCONV=1 docker run -i --rm --name "breeze-cross-$DEB_ARCH" \
    -e "RUST_TARGET=$RUST_TARGET" -e "GCC_TRIPLE=$GCC_TRIPLE" \
    -e "DEB_ARCH=$DEB_ARCH" -e "PY_MINOR=$PY_MINOR" -e "PLAT_TAGS=$PLAT_TAGS" \
    "debian:$SUITE-slim" bash -c '
set -eux
exec 3>&1 1>&2

export DEBIAN_FRONTEND=noninteractive
HOSTARCH="$(dpkg --print-architecture)"
dpkg --add-architecture "$DEB_ARCH"
apt-get update -qq
# gcc-<triple> pulls its own target glibc; libpython3.x-dev:<arch> is the whole
# reason multiarch matters here — it is the target interpreter without emulation.
# Install ONLY native packages. Then fetch the target Python by DOWNLOADING and
# EXTRACTING it, rather than installing it.
#
# Installing it is the obvious move and it does not work. libpythonX.Y-dev:<arch>
# drags in libc6-dev:<arch>, which apt cannot reconcile with the libc6-dev:<host>
# that gcc needs, and the whole transaction dies as "held broken packages". And
# if apt does resolve it, it resolves it the wrong way: it satisfied gcc with
# libc6-dev:mips64el and left the host with no native libc headers at all, so
# `cc` could not link even a trivial program ("cannot find Scrt1.o"). Nothing in
# either failure mentions multiarch.
#
# Extracting sidesteps the resolver entirely: the target files land in /sysroot
# where the cross compiler is explicitly pointed at them, and the host toolchain
# is left alone.
# libc6-dev-<arch>-cross, NOT libc6-dev:<arch>. Debian cross compilers run with
# sysroot / and find their target libc under /usr/<triple>/include, which the
# -cross package provides without colliding with the host libc6-dev. The
# multiarch package is what caused the earlier "held broken packages" deadlock
# and, when apt did resolve it, the missing-host-libc breakage.
apt-get install -y -qq --no-install-recommends "gcc-$GCC_TRIPLE" "libc6-dev-$DEB_ARCH-cross" gcc libc6-dev curl ca-certificates python3 python3-pip python3-venv pkg-config patchelf binutils xz-utils >/dev/null

mkdir -p /sysroot
cd /tmp
apt-get download -qq "libpython$PY_MINOR-dev:$DEB_ARCH" "libpython$PY_MINOR:$DEB_ARCH" "libpython$PY_MINOR-minimal:$DEB_ARCH" "libpython$PY_MINOR-stdlib:$DEB_ARCH" >/dev/null 2>&1 || true
ls -1 /tmp/*.deb | sed "s/^/  fetched /"
for d in /tmp/*.deb; do dpkg-deb -x "$d" /sysroot; done
cd /src 2>/dev/null || cd /
export SYSROOT=/sysroot
export TARGET_INC="/sysroot/usr/include/python$PY_MINOR"
export TARGET_LIB="/sysroot/usr/lib/$GCC_TRIPLE"
ls "$TARGET_LIB/libpython$PY_MINOR.so" >/dev/null 2>&1 || ls "$TARGET_LIB"/libpython"$PY_MINOR"* | head -3
[ -d "$TARGET_INC" ] || { echo "no target Python headers in $TARGET_INC"; ls /sysroot/usr/include | head; exit 1; }
# Note gcc AND libc6-dev pinned to :$HOSTARCH, alongside the cross compiler.
# Both halves matter. Build scripts and proc macros compile for the HOST, so
# rustc needs a native linker (it invokes plain `cc`) as well as the cross one;
# with -Z build-std the number of build scripts explodes, so a missing native
# linker appears as a wall of "could not compile <crate> (build script)" whose
# real cause is one line: "linker `cc` not found".
#
# The :$HOSTARCH pin is the subtler half. Once `dpkg --add-architecture` has been
# run, apt may satisfy the libc6-dev dependency of gcc with the FOREIGN arch --
# it installed libc6-dev:mips64el and no native one, leaving a host cc that
# cannot link anything: "cannot find Scrt1.o", "-lutil" not found. Nothing says
# multiarch; it reads like a broken gcc.
# (Historical note kept because it was mid-diagnosis:)
# macros are compiled for the HOST, and rustc links those with plain `cc`. With
# -Z build-std the number of build scripts explodes, so on a tier 3 target a
# missing native linker surfaces as a wall of "could not compile <crate> (build
# script)" whose single real cause is one line: "linker `cc` not found".

# maturin looks for the target _sysconfigdata*.py inside PYO3_CROSS_LIB_DIR, but
# Debian ships it in the arch-independent stdlib path (/usr/lib/pythonX.Y),
# installed by libpythonX.Y-minimal:<arch>. Copy the matching one next to
# libpython so pyo3 finds it. Without this, maturin dies with "Could not find
# _sysconfigdata*.py" only AFTER the entire toolchain is set up and the sdist
# downloaded — late, and pointing at a directory that looks perfectly fine.
SD="/sysroot/usr/lib/python$PY_MINOR/_sysconfigdata__linux_$GCC_TRIPLE.py"
[ -f "$SD" ] || SD="$(find /sysroot -name "_sysconfigdata*$DEB_ARCH*.py" 2>/dev/null | head -1)"
[ -n "$SD" ] && [ -f "$SD" ] || { echo "no target _sysconfigdata found"; exit 1; }
cp "$SD" "$TARGET_LIB/"
echo "staged $(basename "$SD") into $TARGET_LIB"

# Prove the cross toolchain before spending a Rust build on it: a shared object
# that links libpython is the shape of the real output.
cat > /tmp/t.c <<EOF
#include <Python.h>
PyObject *probe(void) { return PyLong_FromLong(1); }
EOF
# Two -I flags, not one: on Debian, /usr/include/pythonX.Y/pyconfig.h is a stub
# that does #include <TRIPLE/pythonX.Y/pyconfig.h>, so the multiarch include
# root has to be on the path as well or every compile dies on a missing
# pyconfig.h that is in fact present, one directory over.
"$GCC_TRIPLE-gcc" -I"$TARGET_INC" -I"$SYSROOT/usr/include" -shared -fPIC -o /tmp/t.so /tmp/t.c -L"$TARGET_LIB" "-lpython$PY_MINOR"
echo "TOOLCHAIN SMOKE TEST PASSED"
file /tmp/t.so || true

curl -sSf https://sh.rustup.rs -o /tmp/rustup.sh
# nightly + rust-src, both mandatory for -Z build-std on a tier 3 target.
sh /tmp/rustup.sh -y --profile minimal --default-toolchain nightly \
    --component rust-src >/dev/null
export PATH="/root/.cargo/bin:$PATH"
export RUSTUP_TOOLCHAIN=nightly
rustc -vV | head -3

python3 -m pip install --quiet --break-system-packages --upgrade pip maturin wheel packaging

# Read the pinned pydantic-core version from pydantic metadata rather than
# hardcoding, so this cannot drift from requirements.txt.
pip download --quiet --no-deps -d /w/pyd pydantic 2>/dev/null || \
  python3 -m pip download --quiet --no-deps -d /w/pyd pydantic
PCVER="$(python3 - <<PYEOF
import glob, zipfile, re
whl = glob.glob("/w/pyd/pydantic-*.whl")[0]
with zipfile.ZipFile(whl) as z:
    meta = next(n for n in z.namelist() if n.endswith(".dist-info/METADATA"))
    text = z.read(meta).decode()
m = re.search(r"^Requires-Dist: pydantic[-_]core\s*==\s*([0-9][^\s;]*)", text, re.M)
print(m.group(1) if m else "")
PYEOF
)"
[ -n "$PCVER" ] || { echo "could not determine pinned pydantic-core version"; exit 1; }
echo "pydantic pins pydantic-core==$PCVER"

python3 -m pip download --quiet --no-binary pydantic-core --no-deps -d /w/src "pydantic-core==$PCVER"
tar -xzf /w/src/pydantic_core-*.tar.gz -C /w/src
cd /w/src/pydantic_core-*/

U="$(echo "$RUST_TARGET" | tr "a-z-" "A-Z_")"
L="$(echo "$RUST_TARGET" | tr - _)"
export CARGO_TARGET_${U}_LINKER="$GCC_TRIPLE-gcc"
export CC_${L}="$GCC_TRIPLE-gcc"
export AR_${L}="$GCC_TRIPLE-ar"
export PYO3_CROSS=1
export PYO3_CROSS_LIB_DIR="$TARGET_LIB"
export PYO3_CROSS_PYTHON_VERSION="$PY_MINOR"
# The tier 3 knob. Cargo reads -Z flags from this env var, which keeps it working
# through maturin without needing a cargo passthrough.
export CARGO_UNSTABLE_BUILD_STD=std,panic_abort
export CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-$(nproc)}"

# --compatibility linux skips maturin manylinux/musllinux auditing, which is
# not optional on MIPS: the audit uses goblin to parse the ELF and goblin
# misreads MIPS64 section headers, reporting "Symbol table extends beyond file
# boundary (requested: 16106127384, available: 6314136)" for a perfectly good
# 6 MB object. The compile has already succeeded at that point. The target pip
# advertises plain linux_mips64 anyway, so there is nothing to audit against.
maturin build --release --target "$RUST_TARGET" --compatibility linux --out /w/out

cd /w/out
ls -l
# Compare the platform tag EXACTLY, not by substring. maturin names the wheel
# linux_mips64el while the target pip advertises linux_mips64 -- and a substring
# test reports "already correct", because linux_mips64 is a prefix of
# linux_mips64el. The wheel is then silently invisible to pip on the target,
# which is about the hardest failure mode to trace back to this line.
for whl in *.whl; do
  plat="$(basename "$whl" .whl | awk -F- "{print \$NF}")"
  want="$(echo "$PLAT_TAGS" | cut -d, -f1)"
  if [ "$plat" = "$want" ]; then
    echo "tag already exact: $whl"
  else
    args=""
    for t in $(echo "$PLAT_TAGS" | tr , " "); do args="$args --platform-tag $t"; done
    echo "retagging $whl: $plat -> $PLAT_TAGS"
    python3 -m wheel tags $args --remove "$whl"
  fi
done
ls -l
tar -cf - -C /w/out . >&3
' | tar -xf - -C "$OUTABS"

echo "==> wheelhouse:" >&2
ls -1sh "$OUTABS" >&2
