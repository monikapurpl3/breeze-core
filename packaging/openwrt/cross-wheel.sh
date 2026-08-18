#!/usr/bin/env bash
# Cross-build native Python wheels FOR OPENWRT, against the OpenWrt toolchain.
#
#   packaging/openwrt/cross-wheel.sh <owrt-arch> <sdk-target> <rust-target> \
#                                    <py-minor> <plat-tags> <outdir>
#
#   packaging/openwrt/cross-wheel.sh mips_24kc ath79/generic \
#       mips-unknown-linux-musl 3.11 musllinux_1_2_mips,linux_mips \
#       packaging/out/poc/wheelhouse/openwrt-mips_24kc
#
# ── Why a wheelhouse and not a frozen bundle ────────────────────────────────
# A PyInstaller bundle is ~25 MB. Routers have 8-16 MB of flash. The bundle is
# not the useful artifact here; wheels are, because a developer can pip install
# them into an extroot or a chroot and get on with it. This is the "make the
# underlying developer's job easier" deliverable, not a plug-and-play product.
#
# ── Why the OpenWrt SDK and not a generic musl toolchain ────────────────────
# Fidelity. The SDK carries the exact musl, the exact soft-float ABI and the
# exact gcc that OpenWrt built its own python3 with. A "generic musl mips"
# toolchain would approximate the thing we are targeting, and the ABI details
# below are not ones worth approximating.
#
# ── The three OpenWrt-specific traps ────────────────────────────────────────
# 1. SOFT FLOAT, and a suffix that does not match. The loader is
#    /lib/ld-musl-mips-sf.so.1 and the multiarch string is mips-linux-muslSF.
#    Rust's mips*-unknown-linux-musl targets happen to default to
#    "+mips32r2,+soft-float", which matches 24kc exactly — but the extension
#    suffix does not: CPython on the router accepts
#    .cpython-311-mips-linux-muslsf.so, while maturin emits ...-musl.so. That is
#    not in importlib's EXTENSION_SUFFIXES, so the module is invisible and the
#    failure is an ImportError on the device from a wheel that installed
#    cleanly. The .so is therefore renamed inside the wheel.
# 2. NO libpython, and sysconfigdata ships as a .pyc ONLY (OpenWrt strips .py
#    to save flash). pyo3 wants to parse _sysconfigdata*.py and cannot. So the
#    interpreter is described with an explicit PYO3_CONFIG_FILE, which is the
#    supported escape hatch for exactly this situation.
# 3. Tier 3 Rust, as with every MIPS target: nightly + rust-src + -Z build-std.
set -euo pipefail

OWRT_ARCH="${1:?e.g. mips_24kc}"
SDK_TARGET="${2:?e.g. ath79/generic}"
RUST_TARGET="${3:?e.g. mips-unknown-linux-musl}"
PY_MINOR="${4:-3.11}"
PLAT_TAGS="${5:?e.g. musllinux_1_2_mips,linux_mips}"
OUTDIR="${6:?output wheelhouse dir}"
OWRT_VER="${OWRT_VER:-23.05.5}"

mkdir -p "$OUTDIR"; OUTABS="$(cd "$OUTDIR" && pwd)"
echo "==> OpenWrt $OWRT_VER / $OWRT_ARCH ($SDK_TARGET), rust $RUST_TARGET, py $PY_MINOR" >&2

MSYS_NO_PATHCONV=1 docker run -i --rm --name "breeze-owrt-$OWRT_ARCH" \
    -e "OWRT_ARCH=$OWRT_ARCH" -e "SDK_TARGET=$SDK_TARGET" \
    -e "RUST_TARGET=$RUST_TARGET" -e "PY_MINOR=$PY_MINOR" \
    -e "PLAT_TAGS=$PLAT_TAGS" -e "OWRT_VER=$OWRT_VER" \
    debian:bookworm-slim bash -c '
set -eu
exec 3>&1 1>&2

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
    gcc libc6-dev curl ca-certificates xz-utils python3 python3-pip file >/dev/null
mkdir -p /w

BASE="https://downloads.openwrt.org/releases/$OWRT_VER/targets/$SDK_TARGET"
FEED="https://downloads.openwrt.org/releases/$OWRT_VER/packages/$OWRT_ARCH/packages"

echo "=== 1. OpenWrt SDK ==="
SDK_NAME="$(curl -s "$BASE/" | grep -oE "openwrt-sdk-[^\"]*_musl\.Linux-x86_64\.tar\.xz" | sort -u | head -1)"
[ -n "$SDK_NAME" ] || { echo "no SDK found at $BASE"; exit 1; }
echo "  $SDK_NAME"
curl -sSfL -o /tmp/sdk.tar.xz "$BASE/$SDK_NAME"
mkdir -p /sdk && tar -xJf /tmp/sdk.tar.xz -C /sdk --strip-components=1
TC="$(find /sdk/staging_dir -maxdepth 1 -type d -name "toolchain-*" | head -1)"
[ -n "$TC" ] || { echo "no toolchain in SDK"; ls /sdk/staging_dir; exit 1; }
export PATH="$TC/bin:$PATH"
CROSS="$(ls "$TC/bin" | grep -E -- "-gcc$" | head -1)"
[ -n "$CROSS" ] || { echo "no cross gcc in $TC/bin"; ls "$TC/bin" | head; exit 1; }
echo "  toolchain: $TC"
echo "  cross gcc: $CROSS"
"$CROSS" --version | head -1 | sed "s/^/  /"

echo "=== 2. target Python from the feed (ipk, extracted not installed) ==="
mkdir -p /sysroot /tmp/ipk && cd /tmp/ipk
curl -sSfL -o /tmp/Packages "$FEED/Packages"
for p in python3-dev python3-base python3-light; do
  f="$(awk -v want="$p" "/^Package: /{cur=\$2} /^Filename: /{if(cur==want){print \$2; exit}}" /tmp/Packages)"
  if [ -n "$f" ]; then curl -sSfLO "$FEED/$f" && echo "  fetched $f"; else echo "  $p not in feed"; fi
done
# An ipk is a tar.gz whose payload member is data.tar.gz (older) or data.tar.xz.
for f in *.ipk; do
  tar -xzOf "$f" ./data.tar.gz 2>/dev/null | tar -xz -C /sysroot 2>/dev/null && continue
  tar -xzOf "$f" ./data.tar.xz 2>/dev/null | tar -xJ -C /sysroot 2>/dev/null || true
done
[ -f "/sysroot/usr/include/python$PY_MINOR/Python.h" ] || {
  echo "  no Python.h in the extracted sysroot"; find /sysroot -maxdepth 3 -type d | head; exit 1; }
echo "  headers: ok"

# The real extension suffix, derived from the sysconfigdata FILENAME that OpenWrt
# ships. The file itself is a .pyc we cannot read, but its name still carries the
# multiarch string (e.g. _sysconfigdata__linux_mips-linux-muslsf.pyc), which is
# exactly the part that has to end up in the .so name.
SD="$(find /sysroot -name "_sysconfigdata_*" | head -1)"
[ -n "$SD" ] || { echo "  no sysconfigdata in the sysroot"; exit 1; }
MULTI="$(basename "$SD" | sed -e "s/^_sysconfigdata__linux_//" -e "s/\.pyc$//" -e "s/\.py$//")"
[ -n "$MULTI" ] || { echo "  could not derive the multiarch string"; exit 1; }
PYVER_NODOT="$(echo "$PY_MINOR" | tr -d .)"
EXT_SUFFIX=".cpython-$PYVER_NODOT-$MULTI.so"
echo "  multiarch: $MULTI"
echo "  extension suffix the router accepts: $EXT_SUFFIX"

echo "=== 3. rust nightly + rust-src (tier 3 needs build-std) ==="
curl -sSf https://sh.rustup.rs -o /tmp/rustup.sh
sh /tmp/rustup.sh -y --profile minimal --default-toolchain nightly --component rust-src >/dev/null
export PATH="/root/.cargo/bin:$PATH"
export RUSTUP_TOOLCHAIN=nightly
rustc -vV | head -2 | sed "s/^/  /"

python3 -m pip install --quiet --break-system-packages --upgrade pip maturin wheel packaging

echo "=== 4. pinned pydantic-core version ==="
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
[ -n "$PCVER" ] || { echo "could not determine pinned pydantic-core"; exit 1; }
echo "  pydantic-core==$PCVER"
python3 -m pip download --quiet --no-binary pydantic-core --no-deps -d /w/src "pydantic-core==$PCVER"
tar -xzf /w/src/pydantic_core-*.tar.gz -C /w/src
cd /w/src/pydantic_core-*/

echo "=== 5. describe the interpreter explicitly for pyo3 ==="
POINTER_WIDTH=32
case "$RUST_TARGET" in mips64*) POINTER_WIDTH=64 ;; esac
cat > /tmp/pyo3-config.txt <<CFG
implementation=CPython
version=$PY_MINOR
shared=true
abi3=false
lib_name=python$PY_MINOR
lib_dir=/sysroot/usr/lib
pointer_width=$POINTER_WIDTH
build_flags=
suppress_build_script_link_lines=true
CFG
sed "s/^/  /" /tmp/pyo3-config.txt
export PYO3_CONFIG_FILE=/tmp/pyo3-config.txt

U="$(echo "$RUST_TARGET" | tr "a-z-" "A-Z_")"
L="$(echo "$RUST_TARGET" | tr - _)"
export CARGO_TARGET_${U}_LINKER="$TC/bin/$CROSS"
export CC_${L}="$TC/bin/$CROSS"
export CARGO_UNSTABLE_BUILD_STD=std,panic_abort
export CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-$(nproc)}"

echo "=== 6. build ==="
maturin build --release --target "$RUST_TARGET" --compatibility linux --out /w/out

echo "=== 7. retag, then rename the extension module ==="
cd /w/out
for whl in *.whl; do
  plat="$(basename "$whl" .whl | awk -F- "{print \$NF}")"
  want="$(echo "$PLAT_TAGS" | cut -d, -f1)"
  if [ "$plat" != "$want" ]; then
    args=""
    for t in $(echo "$PLAT_TAGS" | tr , " "); do args="$args --platform-tag $t"; done
    echo "  retagging $whl: $plat -> $PLAT_TAGS"
    python3 -m wheel tags $args --remove "$whl"
  else
    echo "  tag already exact: $whl"
  fi
done
# Rename to the suffix the router importer actually looks for. Repacking with
# `wheel pack` recomputes RECORD hashes, which hand-editing would get wrong.
for whl in *.whl; do
  python3 -m wheel unpack -d /w/unpack "$whl" >/dev/null
  d="$(find /w/unpack -maxdepth 1 -mindepth 1 -type d | head -1)"
  changed=0
  for so in $(find "$d" -name "*.so"); do
    b="$(basename "$so")"
    stem="${b%%.*}"
    tgt="$(dirname "$so")/$stem$EXT_SUFFIX"
    if [ "$so" != "$tgt" ]; then
      echo "  renaming $b -> $stem$EXT_SUFFIX"
      mv "$so" "$tgt"; changed=1
    fi
  done
  if [ "$changed" = "1" ]; then
    rm -f "$whl"
    python3 -m wheel pack -d /w/out "$d" >/dev/null
  fi
  rm -rf /w/unpack
done
ls -l /w/out | sed "s/^/  /"
tar -cf - -C /w/out . >&3
' | tar -xf - -C "$OUTABS"

echo "==> wheelhouse:" >&2
ls -1sh "$OUTABS" >&2
