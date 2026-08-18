#!/usr/bin/env bash
# Ask a target platform what it accepts, before spending a build on it.
#
#   packaging/binary/probe-target.sh linux/mips64le mips64le/debian:bookworm-slim
#
# Generalisation of packaging/termux/probe-target.sh, which paid for itself twice
# by disproving assumptions cheaply (see docs/POC-CROSS-BUILDS.md §4). Installs
# nothing but python3 and prints the ABI, the wheel tags its pip will accept, and
# whether the distro simply ships the packages already — which is cheaper than
# any build we could do.
set -euo pipefail

PLATFORM="${1:?e.g. linux/mips64le}"
IMAGE="${2:?e.g. mips64le/debian:bookworm-slim}"
echo "==> probing $IMAGE on $PLATFORM" >&2

MSYS_NO_PATHCONV=1 docker run --rm --platform "$PLATFORM" \
    --name "breeze-probe-$(echo "$PLATFORM" | tr / -)" "$IMAGE" sh -c '
set -eu
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null 2>&1
apt-get install -y -qq --no-install-recommends python3 python3-pip file >/dev/null 2>&1

echo "=============== TARGET REPORT ($(uname -m)) ==============="
echo "python_version    : $(python3 -V 2>&1)"
python3 - <<PYEOF
import sysconfig, sys, platform
g = sysconfig.get_config_var
for label, val in [
    ("get_platform", sysconfig.get_platform()),
    ("SOABI", g("SOABI")),
    ("EXT_SUFFIX", g("EXT_SUFFIX")),
    ("MULTIARCH", g("MULTIARCH")),
    ("HOST_GNU_TYPE", g("HOST_GNU_TYPE")),
    ("LIBDIR", g("LIBDIR")),
    ("INCLUDEPY", g("INCLUDEPY")),
    ("byteorder", sys.byteorder),
    ("platform.machine", platform.machine()),
]:
    print(f"{label:18}: {val}")
PYEOF
echo "--- which wheel tags will this pip install? ---"
python3 -m pip debug --verbose 2>/dev/null | sed -n "/Compatible tags/,\$p" | head -12 \
  || echo "  pip debug unavailable"
echo "--- already packaged by the distro? (cheapest possible win) ---"
for p in python3-pydantic python3-pydantic-core python3-pycryptodome python3-brotli \
         python3-fastapi python3-uvicorn rustc clang; do
  v="$(apt-cache policy "$p" 2>/dev/null | sed -n "s/.*Candidate: //p" | head -1)"
  if [ -n "$v" ] && [ "$v" != "(none)" ]; then echo "  AVAILABLE: $p $v"; else echo "  absent   : $p"; fi
done
echo "================= END REPORT ================="
'
