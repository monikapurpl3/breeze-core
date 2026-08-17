#!/usr/bin/env bash
# Stage A of the cross-build plan: build the native wheels for Termux ON THE
# HOST, at native speed, with no emulation anywhere.
#
#   packaging/termux/cross-wheel.sh aarch64 <sysroot.tar> <outdir>
#
# ── What this replaces ──────────────────────────────────────────────────────
# pydantic-core is a Rust extension and it is the whole reason the emulated
# Termux arm64 build failed: qemu-user deadlocks on the futex traffic of a
# parallel cargo build, twice, at -j4 and again inside maturin. Compiling it here
# instead removes the deadlock by removing the emulator, not by tuning around it.
#
# ── Why only pydantic-core ──────────────────────────────────────────────────
# It is the only dependency that both (a) has no prebuilt Termux package and (b)
# is expensive and thread-hungry to build. pycryptodome is plain C with no build
# parallelism worth speaking of and compiles happily under emulation — it built
# fine on ppc64le that way. Brotli is prebuilt in the Termux repo outright
# (python-brotli). Cross-compiling setuptools-based C extensions needs a whole
# crossenv apparatus for very little gain, so this deliberately does not.
#
# ── The toolchain, and why there is no NDK download ─────────────────────────
# Host clang, aimed at the sysroot exported by export-sysroot.sh:
#   * headers, crt objects, Termux stubs .... Termux ndk-sysroot package
#   * libc/libm/libdl/liblog ................ the image /system/lib64
#   * libpython3.14.so ...................... Termux python package
# aarch64-linux-android is a tier 2 Rust target, so std is prebuilt and none of
# the -Z build-std machinery the MIPS targets will need applies here.
set -euo pipefail

ARCH="${1:-aarch64}"
SYSROOT_TAR="${2:?path to sysroot tar from export-sysroot.sh}"
OUTDIR="${3:-packaging/out/poc/wheelhouse/termux-$ARCH}"
[ -s "$SYSROOT_TAR" ] || { echo "sysroot tar missing or empty: $SYSROOT_TAR" >&2; exit 1; }

case "$ARCH" in
  aarch64) RUST_TARGET=aarch64-linux-android; CLANG_TARGET=aarch64-linux-android24 ;;
  x86_64)  RUST_TARGET=x86_64-linux-android;  CLANG_TARGET=x86_64-linux-android24  ;;
  *) echo "arch must be aarch64 or x86_64" >&2; exit 1 ;;
esac

# Target CPython minor, as measured by probe-target.sh. The wheelhouse is keyed
# by (arch, python-minor) because a non-abi3 extension is bound to one minor.
PY_MINOR="${TERMUX_PY_MINOR:-3.14}"
API="${TERMUX_API_LEVEL:-24}"

mkdir -p "$OUTDIR"
OUTABS="$(cd "$OUTDIR" && pwd)"
echo "==> cross-building for $RUST_TARGET, CPython $PY_MINOR, API $API" >&2
echo "==> wheels -> $OUTABS" >&2

# The host container matches the TARGET python minor version. That is not about
# running the target interpreter (we never do) — it is so the wheel tag and the
# abi3/cp-tag logic in maturin agree with what the target pip expects to see.
tar -cf - -C "$(dirname "$SYSROOT_TAR")" "$(basename "$SYSROOT_TAR")" \
  | MSYS_NO_PATHCONV=1 docker run -i --rm --name "breeze-cross-$ARCH" \
      -e "RUST_TARGET=$RUST_TARGET" -e "CLANG_TARGET=$CLANG_TARGET" \
      -e "PY_MINOR=$PY_MINOR" -e "API=$API" -e "ARCH=$ARCH" \
      -e "SYSROOT_TAR_NAME=$(basename "$SYSROOT_TAR")" \
      "python:$PY_MINOR-slim" bash -c '
set -eux
exec 3>&1 1>&2          # fd 3 carries the wheel tar out

mkdir -p /w && cd /w && tar -xf -
mkdir -p /sysroot && tar -xf "/w/$SYSROOT_TAR_NAME" -C /sysroot

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
# llvm for llvm-ar/llvm-strip: the Android target needs LLVM archivers, and GNU
# ar produces archives the Android linker rejects. lld likewise.
apt-get install -y -qq --no-install-recommends \
    clang lld llvm curl ca-certificates xz-utils patchelf >/dev/null

# One wrapper that is both the C compiler and the Rust linker for this target.
#
# It has to be a real --sysroot, not a pile of -isystem flags. Termux puts
# headers at $PREFIX/include, where clang expects sysroot/usr/include, so the
# obvious move is -isystem /sysroot/include — and that FAILS in a way worth
# recording: -isystem only *adds* a search path, it does not stop clang falling
# back to the host include paths. Bionic limits.h does #include_next <limits.h>,
# which lands on the clang builtin, which lands on the host glibc
# /usr/include/limits.h, which dies on bits/libc-header-start.h. A glibc header
# error while cross-compiling for Android is a confusing way to learn this.
#
# So give clang the layout it wants: /ndk/usr is a symlink to /sysroot, hence
# /ndk/usr/include == /sysroot/include, and --sysroot=/ndk keeps the entire
# header search inside Bionic. (The symlink lives outside /sysroot rather than
# at /sysroot/usr, which would be a self-referential loop that snags tar/find.)
mkdir -p /ndk && ln -sfn /sysroot /ndk/usr
#   -B  so it finds crtbegin_so.o / crtend_so.o
#   -L  Termux libs, then the Bionic system libs from /system/lib64
cat > /usr/local/bin/termux-clang <<WRAP
#!/bin/sh
exec clang --target=$CLANG_TARGET --sysroot=/ndk \
  -B /sysroot/lib \
  -L /sysroot/lib \
  -L /sysroot/system/lib64 \
  "\$@"
WRAP
chmod 755 /usr/local/bin/termux-clang

# The Android clang driver still asks the linker for -lgcc, which has not existed
# since the NDK moved to compiler-rt + libunwind. The NDK shipped exactly this
# workaround for years: a file named libgcc.a that is not an archive at all but a
# linker script redirecting to the replacements. lld honours it, and both
# archives are already in the exported sysroot (they come from ndk-sysroot).
# Without this the link fails with a bare "unable to find library -lgcc", which
# sounds like a missing toolchain rather than a renamed one.
if [ ! -e /sysroot/lib/libgcc.a ]; then
  printf "INPUT(-lunwind -lcompiler_rt-extras)\n" > /sysroot/lib/libgcc.a
  echo "wrote a libgcc.a linker script -> libunwind + compiler_rt-extras"
fi
# Prove the toolchain works before spending a build on it: a shared object that
# links against libc and libpython is exactly the shape of the real output.
cat > /tmp/t.c <<EOF
#include <Python.h>
#include <stdio.h>
PyObject *probe(void) { printf("ok"); return PyLong_FromLong(1); }
EOF
termux-clang -I"/sysroot/include/python$PY_MINOR" -shared -fPIC \
    -o /tmp/t.so /tmp/t.c -lpython$PY_MINOR -lc -lm
echo "TOOLCHAIN SMOKE TEST PASSED:"
python3 -c "print(open(\"/tmp/t.so\",\"rb\").read(20))"

curl -sSf https://sh.rustup.rs -o /tmp/rustup.sh
sh /tmp/rustup.sh -y --profile minimal --default-toolchain stable \
    --target "$RUST_TARGET" >/dev/null
export PATH="/root/.cargo/bin:$PATH"
rustc -vV | head -2

pip install --quiet --upgrade pip maturin wheel packaging

# Which pydantic-core does pydantic pin? Read it from the wheel metadata rather
# than hardcoding, so this does not silently drift from requirements.txt.
pip download --quiet --no-deps -d /w/pyd pydantic
PCVER="$(python3 - <<PYEOF
import glob, zipfile, re, sys
whl = glob.glob("/w/pyd/pydantic-*.whl")[0]
with zipfile.ZipFile(whl) as z:
    meta = next(n for n in z.namelist() if n.endswith(".dist-info/METADATA"))
    text = z.read(meta).decode()
m = re.search(r"^Requires-Dist: pydantic[-_]core\s*==\s*([0-9][^\s;]*)", text, re.M)
print(m.group(1) if m else "")
PYEOF
)"
[ -n "$PCVER" ] || { echo "could not determine the pinned pydantic-core version"; exit 1; }
echo "pydantic pins pydantic-core==$PCVER"

pip download --quiet --no-binary :all: --no-deps -d /w/src "pydantic-core==$PCVER"
tar -xzf /w/src/pydantic_core-*.tar.gz -C /w/src
cd /w/src/pydantic_core-*/

# Force OUR toolchain: the sdist may carry a rust-toolchain.toml, and rustup
# would helpfully install that channel instead — without the Android target we
# just added, so the build would fail on a missing std for the target.
export RUSTUP_TOOLCHAIN=stable
U="$(echo "$RUST_TARGET" | tr "a-z-" "A-Z_")"
export CARGO_TARGET_${U}_LINKER=/usr/local/bin/termux-clang
export CC_$(echo "$RUST_TARGET" | tr - _)=/usr/local/bin/termux-clang
export AR_$(echo "$RUST_TARGET" | tr - _)=llvm-ar
# pyo3 cross-compiles without ever running the target interpreter, given these.
export PYO3_CROSS=1
export PYO3_CROSS_LIB_DIR=/sysroot/lib
export PYO3_CROSS_PYTHON_VERSION="$PY_MINOR"
export CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-$(nproc)}"
# maturin cannot infer this when cross-compiling and fails AFTER the whole Rust
# compile has succeeded ("Failed to determine Android API level"), which is an
# expensive place to learn it. Same variable the on-device Termux build needs.
export ANDROID_API_LEVEL="$API"

maturin build --release --target "$RUST_TARGET" --out /w/out

ls -l /w/out
# Normalise the tag if maturin did not emit an android_* one. The target pip
# prefers cp314-cp314-android_24_arm64_v8a and will not look at linux_aarch64,
# so a mismatch here is an unhelpful "no matching distribution" much later.
cd /w/out
for whl in *.whl; do
  case "$whl" in
    *android*) echo "tag already android: $whl" ;;
    *) echo "retagging $whl -> android_${API}_arm64_v8a"
       python3 -m wheel tags --platform-tag "android_${API}_arm64_v8a" \
           --remove "$whl" ;;
  esac
done
ls -l /w/out
tar -cf - -C /w/out . >&3
' | tar -xf - -C "$OUTABS"

echo "==> wheelhouse contents:" >&2
ls -1sh "$OUTABS" >&2
