#!/usr/bin/env bash
# Stage 0 of the cross-build plan: ask the target what it will accept.
#
#   packaging/termux/probe-target.sh aarch64 > cross-sysroot-aarch64.tar
#
# ── Why this runs before any cross-compiling ────────────────────────────────
# docs/POC-CROSS-BUILDS.md names one unknown that decides whether the whole
# approach works: a cross-built wheel has to be installable by the *target's*
# pip, and its extension modules have to match the target interpreter's ABI. Both
# are facts about Termux's CPython, not things to reason about from the outside —
# maturin may well emit android_24_aarch64 where Termux's pip only accepts
# linux_aarch64, and guessing wrong wastes a full cross-build to find out.
#
# So: install nothing but python in an emulated container, print the tags and
# the ABI, and export the headers, libpython and _sysconfigdata that pyo3 and
# setuptools need pointed at them (PYO3_CROSS_LIB_DIR, _PYTHON_SYSCONFIGDATA_NAME).
#
# This is cheap in a way the failed builds were not: it is a package download and
# an unpack, no compiler runs, so emulation costs minutes. The arm64 deadlock was
# always in cargo — pkg install has never been the problem.
#
# The sysroot tar goes to stdout; the report goes to stderr (and to
# packaging/out/poc/logs/termux-probe-<arch>.txt via the caller's tee).
set -euo pipefail

ARCH="${1:-aarch64}"
case "$ARCH" in
  aarch64|x86_64) : ;;
  *) echo "arch must be aarch64 or x86_64" >&2; exit 1 ;;
esac
IMAGE="termux/termux-docker:$ARCH"

echo "==> probing $IMAGE" >&2

MSYS_NO_PATHCONV=1 docker run -i --rm --name "breeze-probe-$ARCH" "$IMAGE" bash -c '
set -eu
exec 3>&1 1>&2          # fd 3 carries the tar; the report goes to stderr

export TMPDIR="${TMPDIR:-$PREFIX/tmp}"; mkdir -p "$TMPDIR"
# The image ships whichever mirror it was built with (mirrors.zju.edu.cn here,
# which returned Ign: for everything and read as a hang at 0.01% CPU). Pin it.
echo "deb https://packages.termux.dev/apt/termux-main stable main" > "$PREFIX/etc/apt/sources.list"
export DEBIAN_FRONTEND=noninteractive
APT_OPTS="-o Dpkg::Options::=--force-confold -o Dpkg::Options::=--force-confdef"

pkg upgrade -y $APT_OPTS < /dev/null >/dev/null 2>&1 || pkg upgrade -y $APT_OPTS < /dev/null
pkg install -y $APT_OPTS python < /dev/null

PY=python3
V="$($PY -c "import sys;print(f\"{sys.version_info.major}.{sys.version_info.minor}\")")"

echo "=============== TERMUX TARGET REPORT ($(uname -m)) ==============="
echo "android_api_level : $(getprop ro.build.version.sdk 2>/dev/null || echo unknown)"
echo "python_version    : $($PY -V 2>&1)"
echo "python_minor      : $V"
# Quoted heredoc on purpose: unquoted, bash keeps backslash-escaped quotes
# literal and Python sees g(\"SOABI\") — a syntax error 20 minutes into an
# emulated run. Nothing in here needs shell expansion.
$PY - <<'PYEOF'
import sysconfig, sys, platform
g = sysconfig.get_config_var
for label, val in [
    ("get_platform", sysconfig.get_platform()),
    ("SOABI", g("SOABI")),
    ("EXT_SUFFIX", g("EXT_SUFFIX")),
    ("MULTIARCH", g("MULTIARCH")),
    ("ANDROID_API_LEVEL", g("ANDROID_API_LEVEL")),
    ("HOST_GNU_TYPE", g("HOST_GNU_TYPE")),
    ("CC (build-time)", g("CC")),
    ("LDSHARED", g("LDSHARED")),
    ("LIBDIR", g("LIBDIR")),
    ("INCLUDEPY", g("INCLUDEPY")),
    ("Py_GIL_DISABLED", g("Py_GIL_DISABLED")),
    ("platform.machine", platform.machine()),
    ("sys.platform", sys.platform),
]:
    print(f"{label:18}: {val}")
PYEOF
echo "--- sysconfigdata module (name matters: _PYTHON_SYSCONFIGDATA_NAME) ---"
ls "$PREFIX/lib/python$V/" | grep -i sysconfigdata || echo "  NONE FOUND"
echo "--- libpython ---"
ls -l "$PREFIX/lib/"libpython*.so* 2>/dev/null || echo "  no shared libpython (static build?)"
echo "--- THE DECIDING QUESTION: which wheel tags will this pip install? ---"
# pip debug --verbose lists every compatible tag, most-preferred first. If
# android_* appears, maturin output is directly installable; if only linux_* and
# generic tags appear, cross-built wheels must be retagged before install.
$PY -m pip debug --verbose 2>/dev/null | sed -n "/Compatible tags/,\$p" | head -30 \
  || echo "  pip debug unavailable"
echo "--- does the Termux repo simply have these prebuilt? (cheapest possible win) ---"
for p in python-pydantic python-pydantic-core python-cryptography python-pycryptodome python-brotli; do
  if apt-cache show "$p" >/dev/null 2>&1; then
    echo "  AVAILABLE: $p $(apt-cache policy "$p" 2>/dev/null | sed -n "s/.*Candidate: //p" | head -1)"
  else
    echo "  absent   : $p"
  fi
done
echo "================= END REPORT ================="

# Export exactly what a cross-compile needs to be pointed at.
cd "$PREFIX"
tar -cf - \
    "include/python$V" \
    lib/libpython*.so* \
    "lib/python$V/_sysconfigdata"*.py \
    >&3
'
echo "==> probe done" >&2
