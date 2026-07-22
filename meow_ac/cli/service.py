"""
Host-local background-service inspection for `breeze-core diag`.

Answers two questions about the breeze-core service *on the machine diag is
running on*: is it **running**, and is it **enabled to start at boot**?
Detects the init/service manager (systemd, OpenRC, runit, procd/SysV
init.d, or Windows `sc`) and degrades gracefully — if diag is run somewhere
that isn't the server, there's simply no managed service to find and the
check is skipped rather than failing.

Pure standard library (subprocess to the system service tools); works the
same frozen in the single binary as from source.
"""
from __future__ import annotations

import os
import platform
import re
import shutil
import subprocess
from dataclasses import dataclass
from typing import List, Optional

# Candidate unit names, most-likely first. `breeze-core` is the packaged
# name; `meow-ac` is the original source-install name still in the wild.
UNIX_NAMES = ["breeze-core", "meow-ac"]
WINDOWS_NAMES = ["BreezeCore", "breeze-core"]


@dataclass
class ServiceStatus:
    manager: str                 # systemd | openrc | runit | init.d | windows-sc | none
    name: Optional[str] = None   # the service name that matched
    found: bool = False          # a managed breeze-core/meow-ac service exists here
    running: Optional[bool] = None   # None = couldn't tell
    boot: Optional[bool] = None      # enabled at boot; None = couldn't tell
    detail: str = ""


def _run(cmd: List[str], timeout: int = 5):
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return p.returncode, (p.stdout or "").strip(), (p.stderr or "").strip()
    except (OSError, subprocess.SubprocessError):
        return 127, "", ""


def _candidates(extra_name: Optional[str]) -> List[str]:
    base = WINDOWS_NAMES if platform.system() == "Windows" else UNIX_NAMES
    if extra_name and extra_name not in base:
        return [extra_name] + base
    return base


def detect(extra_name: Optional[str] = None) -> ServiceStatus:
    names = _candidates(extra_name)
    if platform.system() == "Windows":
        return _windows(names)
    if shutil.which("systemctl") and os.path.isdir("/run/systemd/system"):
        return _systemd(names)
    if shutil.which("rc-service"):
        return _openrc(names)
    if shutil.which("sv") and os.path.isdir("/etc/sv"):
        return _runit(names)
    if os.path.isdir("/etc/init.d"):
        return _initd(names)
    return ServiceStatus("none")


def _systemd(names: List[str]) -> ServiceStatus:
    for name in names:
        _, out, _ = _run(["systemctl", "list-unit-files", f"{name}.service", "--no-legend"])
        if not out.strip():
            continue
        _, active, _ = _run(["systemctl", "is-active", name])
        _, enabled, _ = _run(["systemctl", "is-enabled", name])
        return ServiceStatus(
            "systemd", name, True,
            running=(active == "active"),
            boot=(enabled == "enabled"),
            detail=f"is-active={active or '?'}, is-enabled={enabled or '?'}",
        )
    return ServiceStatus("systemd", found=False)


def _openrc(names: List[str]) -> ServiceStatus:
    _, show, _ = _run(["rc-update", "show"])
    for name in names:
        if not os.path.exists(f"/etc/init.d/{name}"):
            continue
        rc, out, _ = _run(["rc-service", name, "status"])
        boot = bool(re.search(rf'(^|\s){re.escape(name)}\s', show))
        return ServiceStatus(
            "openrc", name, True,
            running=(rc == 0),
            boot=boot,
            detail=(out.splitlines()[0] if out else ""),
        )
    return ServiceStatus("openrc", found=False)


def _runit(names: List[str]) -> ServiceStatus:
    for name in names:
        if not os.path.isdir(f"/etc/sv/{name}"):
            continue
        _, out, _ = _run(["sv", "status", name])
        running = out.startswith("run:")
        boot = any(
            os.path.islink(p)
            for p in (f"/var/service/{name}", f"/etc/service/{name}",
                      f"/etc/runit/runsvdir/default/{name}")
        )
        return ServiceStatus("runit", name, True, running, boot,
                             detail=(out.splitlines()[0] if out else ""))
    return ServiceStatus("runit", found=False)


def _initd(names: List[str]) -> ServiceStatus:
    for name in names:
        path = f"/etc/init.d/{name}"
        if not os.path.exists(path):
            continue
        # procd (OpenWrt) understands `enabled` and `running`; SysV has `status`.
        rc_en, _, _ = _run([path, "enabled"])
        boot: Optional[bool] = True if rc_en == 0 else (False if rc_en == 1 else None)
        rc_run, _, _ = _run([path, "running"])
        if rc_run in (0, 1):
            running: Optional[bool] = (rc_run == 0)
        else:
            rc_st, _, _ = _run([path, "status"])
            running = (rc_st == 0) if rc_st in (0, 3) else None
        return ServiceStatus("init.d", name, True, running, boot, detail="procd/sysv")
    return ServiceStatus("init.d", found=False)


def _windows(names: List[str]) -> ServiceStatus:
    for name in names:
        rc, out, err = _run(["sc", "query", name])
        blob = (out + err)
        if "1060" in blob or "does not exist" in blob.lower():
            continue
        if rc != 0 and not out:
            continue
        running = "RUNNING" in out
        _, qc, _ = _run(["sc", "qc", name])
        boot = "AUTO_START" in qc if qc else None
        return ServiceStatus("windows-sc", name, True, running, boot, detail="")
    return ServiceStatus("windows-sc", found=False)
