"""
Everything the server knows about itself, for the app's "Nerd" screen.

Design rules for this module, because it exists to be *displayed* rather than
acted on:

- **Never raise.** Every probe is wrapped; a fact that can't be determined
  becomes `None` (or a short "unknown"), never a 500. A diagnostics screen
  that fails to load is worse than one with a blank row.
- **Never block for long.** Nothing here does network I/O or shells out to
  anything slow. The two subprocess calls (`sysctl` on the BSDs, `uname` as a
  last resort) have hard timeouts.
- **Static facts are cached.** The OS, CPU, init system and dependency
  versions can't change while the process runs, so they're resolved once.
  Live facts (uptime, counts, timestamps) are recomputed per call.
- **No secrets.** Not the API key, not device secrets, not V3 unit
  token/keys. Paths and version numbers are fine — the endpoint already
  requires the API key *and* a device credential — but anything that would
  let a reader authenticate stays out. `has_v3_credentials` is a boolean for
  exactly this reason.
"""
from __future__ import annotations

import functools
import os
import platform
import socket
import subprocess
import sys
import time
from pathlib import Path
from typing import Any, Dict, List, Optional

from meow_ac import __version__

# Process start, captured at import. Used for uptime — /proc/uptime is the
# machine's, which is a different (also interesting) number.
_STARTED_AT = time.time()


def _safe(fn, default=None):
    """Run a probe, swallowing anything it throws."""
    try:
        return fn()
    except Exception:
        return default


def _run(cmd: List[str], timeout: int = 3) -> Optional[str]:
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        if out.returncode == 0:
            return out.stdout.strip() or None
    except (OSError, subprocess.SubprocessError):
        pass
    return None


# --- operating system -------------------------------------------------------

def _os_release() -> Dict[str, str]:
    """Parse /etc/os-release into a dict. Present on every modern Linux and on
    recent FreeBSD; absent on OpenBSD/NetBSD/macOS/Windows, where the caller
    falls back to `platform`."""
    data: Dict[str, str] = {}
    for path in ("/etc/os-release", "/usr/lib/os-release"):
        try:
            with open(path, encoding="utf-8") as fh:
                for line in fh:
                    if "=" not in line:
                        continue
                    k, _, v = line.partition("=")
                    data[k.strip()] = v.strip().strip('"').strip("'")
            if data:
                return data
        except OSError:
            continue
    return data


@functools.lru_cache(maxsize=1)
def operating_system() -> Dict[str, Any]:
    rel = _safe(_os_release, {}) or {}
    system = platform.system()          # Linux / FreeBSD / OpenBSD / Darwin / Windows

    pretty = rel.get("PRETTY_NAME") or rel.get("NAME")
    if not pretty:
        if system == "Darwin":
            ver = _safe(lambda: platform.mac_ver()[0])
            pretty = f"macOS {ver}" if ver else "macOS"
        elif system == "Windows":
            pretty = f"Windows {platform.release()}"
        else:
            # The BSDs: `uname -sr` is the honest answer.
            pretty = f"{system} {platform.release()}".strip()

    return {
        "system": system,                     # kernel family
        "pretty_name": pretty,                # "Fedora Linux 42 (Server Edition)"
        "distro_id": rel.get("ID"),           # "fedora", "debian", "alpine"…
        "distro_version": rel.get("VERSION_ID"),
        "kernel": platform.release(),
        "kernel_version": platform.version() or None,
        "hostname": _safe(socket.gethostname),
        "libc": _safe(lambda: " ".join(platform.libc_ver()).strip() or None),
    }


# --- init system ------------------------------------------------------------

@functools.lru_cache(maxsize=1)
def init_system() -> Dict[str, Any]:
    """Which service manager is in charge.

    `cli/service.py` already detects the Linux ones (it drives `diag`), so
    reuse it rather than growing a second implementation, then extend for the
    platforms it doesn't cover: the BSDs' rc, macOS launchd, and Windows SCM.
    """
    system = platform.system()

    if system == "Darwin":
        return {"name": "launchd", "detail": None}
    if system == "Windows":
        return {"name": "windows-sc", "detail": "Windows Service Control Manager"}
    if system in ("FreeBSD", "OpenBSD", "NetBSD", "DragonFly"):
        return {"name": "rc.d", "detail": f"{system} rc(8)"}

    try:
        from meow_ac.cli import service as service_mod

        status = service_mod.detect("breeze-core")
        name = getattr(status, "manager", None)
        if name and name != "none":
            detail = None
            if getattr(status, "found", False):
                unit = getattr(status, "unit", None) or getattr(status, "name", None)
                running = getattr(status, "running", None)
                detail = f"{unit}: {'running' if running else 'not running'}" if unit else None
            return {"name": name, "detail": detail}
    except Exception:
        pass

    # Last resort: read pid 1's name. Catches the container case (the app is
    # pid 1, or tini/dumb-init is), where no service manager is involved.
    comm = _safe(lambda: Path("/proc/1/comm").read_text().strip())
    if comm:
        return {"name": comm, "detail": "from /proc/1/comm"}
    return {"name": "unknown", "detail": None}


# --- hardware ---------------------------------------------------------------

@functools.lru_cache(maxsize=1)
def cpu() -> Dict[str, Any]:
    model = None
    system = platform.system()
    if system == "Linux":
        def _from_cpuinfo():
            for line in Path("/proc/cpuinfo").read_text().splitlines():
                # x86 says "model name", ARM says "Hardware"/"Model", s390 "machine".
                for key in ("model name", "Model", "Hardware", "cpu model"):
                    if line.lower().startswith(key.lower()):
                        return line.split(":", 1)[1].strip()
            return None
        model = _safe(_from_cpuinfo)
    elif system == "Darwin":
        model = _run(["sysctl", "-n", "machdep.cpu.brand_string"])
    elif system in ("FreeBSD", "OpenBSD", "NetBSD", "DragonFly"):
        model = _run(["sysctl", "-n", "hw.model"])
    elif system == "Windows":
        model = os.environ.get("PROCESSOR_IDENTIFIER")

    return {
        "arch": platform.machine(),                     # x86_64 / aarch64 / riscv64
        "model": model or platform.processor() or None,
        "cores": _safe(os.cpu_count),
        "endianness": sys.byteorder,
    }


def _machine_uptime() -> Optional[float]:
    """Seconds since boot, where the OS will tell us cheaply."""
    v = _safe(lambda: float(Path("/proc/uptime").read_text().split()[0]))
    if v is not None:
        return v
    if platform.system() in ("FreeBSD", "OpenBSD", "NetBSD", "Darwin", "DragonFly"):
        raw = _run(["sysctl", "-n", "kern.boottime"])
        if not raw:
            return None
        # Two formats in the wild, and OpenBSD uses the second one:
        #   FreeBSD/NetBSD/macOS:  { sec = 1755200000, usec = 1 } Tue Aug ...
        #   OpenBSD:               1755200000
        try:
            if "sec = " in raw:
                sec = int(raw.split("sec = ")[1].split(",")[0].strip())
            else:
                sec = int(raw.split()[0])
            return max(0.0, time.time() - sec)
        except (ValueError, IndexError):
            return None
    return None


# --- python + dependencies --------------------------------------------------

#: Runtime dependencies worth reporting. `msmart-ng` is the one that actually
#: decides whether a given AC model works, so it matters most.
_COMPONENTS = [
    "msmart-ng", "fastapi", "uvicorn", "starlette", "pydantic",
    "pydantic-core", "brotli-asgi", "cryptography", "httpx", "anyio",
]


@functools.lru_cache(maxsize=1)
def components() -> Dict[str, Optional[str]]:
    """Installed version of each dependency, `None` if it isn't installed.

    A missing entry is information, not an error: no `brotli-asgi` means
    responses fall back to gzip, and that's worth seeing on this screen.
    """
    from importlib.metadata import PackageNotFoundError, version as pkg_version

    out: Dict[str, Optional[str]] = {}
    for name in _COMPONENTS:
        try:
            out[name] = pkg_version(name)
        except PackageNotFoundError:
            out[name] = None
        except Exception:
            out[name] = None
    return out


@functools.lru_cache(maxsize=1)
def python_info() -> Dict[str, Any]:
    return {
        "version": platform.python_version(),
        "implementation": platform.python_implementation(),
        "executable": sys.executable or None,
        # PyInstaller sets sys.frozen; the packages ship a frozen bundle, so
        # "is this the self-contained build or a venv?" is answerable here.
        "frozen": bool(getattr(sys, "frozen", False)),
    }


# --- network ----------------------------------------------------------------

def local_addresses() -> List[str]:
    """The server's own IP addresses, best-effort and without touching the
    network: the UDP-connect trick for the primary one, plus whatever the
    hostname resolves to. Reported so the app can tell the user the real LAN
    address even when they reached the server through a proxy or a hostname."""
    found: List[str] = []

    def _primary():
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            # No packet is sent — connect() on UDP just picks the route.
            s.connect(("192.0.2.1", 9))    # TEST-NET-1, never routed
            return s.getsockname()[0]
        finally:
            s.close()

    primary = _safe(_primary)
    if primary:
        found.append(primary)

    def _by_hostname():
        host = socket.gethostname()
        return [ai[4][0] for ai in socket.getaddrinfo(host, None)]

    for addr in _safe(_by_hostname, []) or []:
        if addr not in found and not addr.startswith("127.") and addr != "::1":
            found.append(addr)
    return found


# --- install time -----------------------------------------------------------

def installed_at(config_path: Path) -> Optional[float]:
    """When this deployment was first set up, approximated by the oldest
    mtime among the things that only exist once it has been: the config file
    and the program directory. Creation time isn't portable (Linux stat has no
    birth time on most filesystems), so this is the honest available answer —
    and it survives upgrades, which rewrite the program dir but not the config."""
    candidates: List[float] = []
    for p in (config_path, Path(__file__).resolve().parent):
        try:
            st = p.stat()
            # st_birthtime exists on the BSDs/macOS and is the real answer there.
            candidates.append(float(getattr(st, "st_birthtime", st.st_mtime)))
        except OSError:
            continue
    return min(candidates) if candidates else None


# --- the whole picture ------------------------------------------------------

def snapshot(settings, *, config_path: Path) -> Dict[str, Any]:
    """Host + runtime facts. Callers add the live, per-request parts."""
    now = time.time()
    return {
        "server": {
            "name": "Breeze Core",
            "version": __version__,
            "python": python_info(),
            "started_at": _STARTED_AT,
            "uptime_seconds": round(now - _STARTED_AT, 1),
            "installed_at": installed_at(config_path),
            "timezone": _safe(lambda: time.strftime("%Z")),
            "utc_offset_seconds": _safe(
                lambda: -(time.altzone if time.daylight and time.localtime().tm_isdst else time.timezone)
            ),
            "server_time": now,
        },
        "os": operating_system(),
        "init": init_system(),
        "cpu": cpu(),
        "machine_uptime_seconds": _safe(_machine_uptime),
        "components": components(),
        "network": {
            "hostname": _safe(socket.gethostname),
            "local_addresses": local_addresses(),
            "bind_host": os.environ.get("BREEZE_HOST") or os.environ.get("AC_HOST"),
            "bind_port": os.environ.get("BREEZE_PORT") or os.environ.get("AC_PORT"),
        },
        "paths": {
            "config": str(config_path),
            "devices": str(settings.devices_path),
            "programs": str(settings.programs_path),
            "package": str(Path(__file__).resolve().parent),
        },
        "settings": {
            "docs_enabled": settings.docs_enabled,
            "security_headers": settings.security_headers,
            "compression": settings.compression,
            "behind_proxy": settings.behind_proxy,
            "enrollment_lan_only": settings.enrollment_lan_only,
            "trusted_hosts": settings.trusted_hosts,
            "token_ttl_days": settings.token_ttl_days,
            "code_ttl_seconds": settings.code_ttl_seconds,
            "auth_skew_seconds": settings.auth_skew_seconds,
            "min_auth_version": settings.min_auth_version,
            "scheduler_tick_seconds": settings.scheduler_tick_seconds,
            "stream_tick_seconds": settings.stream_tick_seconds,
            "history_size": settings.history_size,
        },
    }
