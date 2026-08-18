#!/usr/bin/env bash
# Prove an OpenWrt wheel actually imports and runs on its target architecture.
#
#   packaging/openwrt/verify-wheel.sh <owrt-arch> <qemu-arch> <target-path> <wheelhouse>
#
#   packaging/openwrt/verify-wheel.sh mipsel_24kc mipsel ramips/mt7621 \
#       packaging/out/poc/wheelhouse/openwrt-mipsel_24kc
#
# ── Why this exists rather than "just run the rootfs image" ──────────────────
# OpenWrt publishes a Docker rootfs for only a handful of architectures — of the
# eight MIPS ones, just mips_24kc — and in 23.05.5 the malta target has only a
# `be` subtarget, so there is no little-endian rootfs image or tarball to be had
# at all. Without this, mipsel and mips64 wheels could be inspected but never
# executed, which is exactly the sort of "looks correct" this exercise keeps
# disproving.
#
# So the userland is assembled from the feeds: resolve python3-light's
# dependencies, download the ipks, extract them into a sysroot, and run the
# target interpreter under qemu-user directly. No binfmt registration needed,
# because qemu is invoked explicitly.
#
# ── Two details that make or break it ───────────────────────────────────────
# 1. THREE feeds, not two. libc (musl) — and therefore the ELF loader
#    /lib/ld-musl-*.so.1 — is not in packages/<arch>/base at all; it lives in the
#    target's own core feed under targets/<target>/packages. Miss it and qemu
#    stops with "Could not open '/lib/ld-musl-mipsel-sf.so.1'", which reads like
#    a qemu problem rather than a missing package.
# 2. PYTHONHOME. qemu-user does NOT chroot, so the emulated interpreter resolves
#    /usr/lib/python3.11 against the HOST filesystem and would happily import
#    Debian's own 3.11 stdlib — appearing to work while testing nothing at all.
#    Pointing PYTHONHOME at the sysroot is what makes this a real test.
set -euo pipefail

OWRT_ARCH="${1:?e.g. mipsel_24kc}"
QEMU_ARCH="${2:?e.g. mipsel}"
TARGET_PATH="${3:?e.g. ramips/mt7621 — needed for the core feed that carries libc}"
WHEELDIR="${4:?wheelhouse directory}"
OWRT_VER="${OWRT_VER:-23.05.5}"
PY_MINOR="${PY_MINOR:-3.11}"

ls "$WHEELDIR"/*.whl >/dev/null 2>&1 || { echo "no wheels in $WHEELDIR" >&2; exit 1; }
echo "==> verifying $OWRT_ARCH wheels under qemu-$QEMU_ARCH (core feed: $TARGET_PATH)" >&2

tar -cf - -C "$WHEELDIR" . | MSYS_NO_PATHCONV=1 docker run -i --rm \
    --name "breeze-owrt-verify-$OWRT_ARCH" \
    -e "OWRT_ARCH=$OWRT_ARCH" -e "QEMU_ARCH=$QEMU_ARCH" \
    -e "TARGET_PATH=$TARGET_PATH" \
    -e "OWRT_VER=$OWRT_VER" -e "PY_MINOR=$PY_MINOR" \
    -e "QEMU_CPU=${QEMU_CPU:-}" \
    debian:bookworm-slim bash -c '
set -eu
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
    qemu-user-static curl ca-certificates python3 python3-pip file xz-utils >/dev/null

mkdir -p /wh && cd /wh && tar -xf -
echo "wheels under test:"; ls -1 /wh | sed "s/^/  /"

REL="https://downloads.openwrt.org/releases/$OWRT_VER"
mkdir -p /idx /ipk /sysroot
# core carries libc/musl; base and packages carry python3 and friends.
echo "$REL/targets/$TARGET_PATH/packages" > /idx/core.url
echo "$REL/packages/$OWRT_ARCH/base"      > /idx/base.url
echo "$REL/packages/$OWRT_ARCH/packages"  > /idx/packages.url
for feed in core base packages; do
  curl -sSfL -o "/idx/$feed" "$(cat /idx/$feed.url)/Packages" \
    && echo "  index: $feed ($(grep -c "^Package: " "/idx/$feed") packages)" \
    || echo "  index: $feed UNAVAILABLE"
done

python3 - <<PYEOF
import os, re, urllib.request
feeds, bases = {}, {}
for name in ("core", "base", "packages"):
    idx = "/idx/" + name
    if not os.path.exists(idx):
        continue
    bases[name] = open("/idx/" + name + ".url").read().strip()
    for block in open(idx, encoding="utf-8", errors="replace").read().split("\n\n"):
        pkg = re.search(r"^Package: (\S+)", block, re.M)
        fn = re.search(r"^Filename: (\S+)", block, re.M)
        if not pkg or not fn:
            continue
        deps = []
        d = re.search(r"^Depends: (.+)$", block, re.M)
        if d:
            for part in d.group(1).split(","):
                part = part.strip().split(" ")[0].strip()
                if part:
                    deps.append(part)
        feeds.setdefault(pkg.group(1), (name, fn.group(1), deps))

# python3 (the meta-package), not python3-light: OpenWrt splits the stdlib into
# many small packages to save flash, so python3-light lacks decimal, email and
# others. pydantic_core imports decimal at module scope, and the resulting
# ModuleNotFoundError looks like a broken wheel rather than a partial stdlib.
want = ["python3", "python3-light", "python3-base", "libc"]
seen, order = set(), []
while want:
    name = want.pop(0)
    if name in seen or name not in feeds:
        continue
    seen.add(name)
    order.append(name)
    want.extend(feeds[name][2])
missing = [n for n in ("python3", "libc") if n not in seen]
print("resolved %d packages%s" % (len(order), (" MISSING:" + ",".join(missing)) if missing else ""))
for name in order:
    feed, fn, _ = feeds[name]
    try:
        urllib.request.urlretrieve(bases[feed] + "/" + fn, "/ipk/" + os.path.basename(fn))
    except Exception as exc:
        print("  skip %s (%s)" % (name, exc))
PYEOF

cd /ipk
for f in *.ipk; do
  tar -xzOf "$f" ./data.tar.gz 2>/dev/null | tar -xz -C /sysroot 2>/dev/null && continue
  tar -xzOf "$f" ./data.tar.xz 2>/dev/null | tar -xJ -C /sysroot 2>/dev/null || true
done
# The musl loader is NOT installable from any feed: OpenWrt bakes libc into the
# firmware image, so "Depends: libc" is satisfied by the base system and no libc
# ipk exists. The runtime therefore has to come from the SDK toolchain, which is
# also the only copy guaranteed to match the ABI the wheel was built against.
if ! ls /sysroot/lib/ld-musl-* >/dev/null 2>&1; then
  echo "no musl loader from the feeds (expected) — taking it from the SDK toolchain"
  SDKBASE="$REL/targets/$TARGET_PATH"
  SDK_NAME="$(curl -s "$SDKBASE/" | grep -oE "openwrt-sdk-[^\"]*_musl\.Linux-x86_64\.tar\.xz" | sort -u | head -1)"
  [ -n "$SDK_NAME" ] || { echo "  no SDK at $SDKBASE"; exit 1; }
  curl -sSfL -o /tmp/sdk.tar.xz "$SDKBASE/$SDK_NAME"
  mkdir -p /sdk && tar -xJf /tmp/sdk.tar.xz -C /sdk --strip-components=1
  TC="$(find /sdk/staging_dir -maxdepth 1 -type d -name "toolchain-*" | head -1)"
  mkdir -p /sysroot/lib
  find "$TC" -maxdepth 3 -name "ld-musl-*.so.1" -exec cp -a {} /sysroot/lib/ \; 2>/dev/null || true
  find "$TC" -maxdepth 3 -name "libc.so" -exec cp -a {} /sysroot/lib/ \; 2>/dev/null || true
fi
echo "musl loader in the sysroot:"; ls /sysroot/lib/ld-musl-* 2>/dev/null | sed "s/^/  /" || echo "  NONE — qemu cannot start anything"

PYBIN="/sysroot/usr/bin/python$PY_MINOR"
[ -x "$PYBIN" ] || { echo "no target interpreter at $PYBIN"; find /sysroot/usr/bin -maxdepth 1 | head; exit 1; }
echo "target interpreter:"; file -b "$PYBIN" | cut -c1-100 | sed "s/^/  /"

# Install by unzipping: pip here is a target binary, and the claim under test is
# "does this extension module load and run", not "does pip resolve dependencies".
SITE="/sysroot/usr/lib/python$PY_MINOR/site-packages"
mkdir -p "$SITE"
for w in /wh/*.whl; do
  python3 -c "import zipfile,sys; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])" "$w" "$SITE"
  echo "  unpacked $(basename "$w")"
done
# pydantic_core imports typing_extensions at module scope. It is pure Python
# (py3-none-any), so the host pip can fetch it and it drops straight into the
# target site-packages -- no cross-build needed, and its absence would otherwise
# read as a broken extension module.
python3 -m pip download --quiet --no-deps --dest /tmp/pure typing_extensions >/dev/null 2>&1 || true
for w in /tmp/pure/*.whl; do
  [ -f "$w" ] || continue
  python3 -c "import zipfile,sys; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])" "$w" "$SITE"
  echo "  unpacked $(basename "$w") (pure python)"
done
echo "extension module as installed:"
find "$SITE" -name "*.so" | while read -r so; do
  echo "  $(basename "$so")"
  file -b "$so" | cut -c1-105 | sed "s/^/    /"
done

export PYTHONHOME=/sysroot/usr
export PYTHONPATH="/sysroot/usr/lib/python$PY_MINOR:$SITE"
export PYTHONDONTWRITEBYTECODE=1
# QEMU_CPU is honoured by qemu-user directly, and is needed for targets built
# with CPU-specific instructions: OpenWrt compiles mips64_octeonplus with
# -march=octeon+, which the default generic MIPS64R2 model does not implement,
# so the INTERPRETER dies with SIGILL before the wheel is ever reached --
# indistinguishable from a broken wheel unless you know to look. Octeon68XX
# fixes it; empty is correct for 24kc.
echo "=== running the target interpreter under qemu-$QEMU_ARCH${QEMU_CPU:+ (cpu $QEMU_CPU)} ==="
"/usr/bin/qemu-$QEMU_ARCH-static" -L /sysroot "$PYBIN" -c "
import sys, sysconfig
print(\"  python       :\", sys.version.split()[0], \"byteorder=\" + sys.byteorder)
print(\"  ext suffix   :\", sysconfig.get_config_var(\"EXT_SUFFIX\"))
import pydantic_core
from pydantic_core import SchemaValidator
print(\"  pydantic_core:\", pydantic_core.__version__)
print(\"  loaded       :\", pydantic_core._pydantic_core.__file__.split(\"/\")[-1])
v = SchemaValidator({\"type\": \"float\", \"ge\": 16.0, \"le\": 30.0})
print(\"  validate 22.5 ->\", v.validate_python(22.5))
try:
    v.validate_python(99.0)
    print(\"  validate 99.0 -> NOT REJECTED (wrong)\")
except Exception as exc:
    print(\"  validate 99.0 -> rejected:\", type(exc).__name__)
"
'
