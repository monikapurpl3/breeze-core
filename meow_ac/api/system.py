"""
`GET /api/system` — everything about this deployment, in one response.

This backs the Breeze app's "Nerd" screen. It's one endpoint rather than a
dozen because the screen wants the whole picture at once, and because a phone
on a LAN pays a round-trip per call.

**Auth:** API key **and** a device credential — the same bar as controlling a
unit. It reports OS, paths, dependency versions and the enrolled device list,
which is exactly the reconnaissance an attacker would want and exactly what
the owner wants on a diagnostics screen. It is deliberately *not* LAN-gated,
because the person most likely to need it is the one who's away from home
wondering why their AC won't answer.

**No secrets, ever.** No API key, no device secrets or public keys, no V3 unit
token/key — `has_v3_credentials` is a boolean. See `system_info` for the rest
of the rules this file follows.
"""
from __future__ import annotations

import os
import time
from pathlib import Path
from typing import Any, Dict, List, Optional

from fastapi import APIRouter, Depends, Request

from meow_ac import system_info
from meow_ac.api.meta import AUTH_VERSIONS, FEATURES, _commit
from meow_ac.config.store import ConfigStore
from meow_ac.devices.history import HistoryBuffer
from meow_ac.devices.manager import DeviceManager
from meow_ac.devices.schemas import serialize_capabilities
from meow_ac.programs.store import ProgramStore
from meow_ac.security.base import Authenticator
from meow_ac.security.net import client_ip, is_private_ip
from meow_ac.security.token_store import TokenStore
from meow_ac.settings import Settings


def _file_facts(path: Path) -> Dict[str, Any]:
    """Existence, size, mode and mtime of one of the stores. Mode is reported
    as a string because `0o640` matters here — a config that's world-readable
    is a finding, and this is the screen where someone would notice."""
    try:
        st = path.stat()
        return {
            "path": str(path),
            "exists": True,
            "size_bytes": st.st_size,
            "mode": oct(st.st_mode & 0o777),
            "modified_at": st.st_mtime,
        }
    except OSError:
        return {"path": str(path), "exists": False}


def _process() -> Dict[str, Any]:
    facts: Dict[str, Any] = {"pid": os.getpid()}
    try:  # Linux-only, and free: no psutil dependency for one number.
        parts = Path("/proc/self/statm").read_text().split()
        facts["rss_bytes"] = int(parts[1]) * os.sysconf("SC_PAGE_SIZE")
    except (OSError, ValueError, IndexError, AttributeError):
        pass
    return facts


def build_system_router(
    store: ConfigStore,
    manager: DeviceManager,
    token_store: TokenStore,
    program_store: ProgramStore,
    scheduler,
    history: HistoryBuffer,
    settings: Settings,
    authenticator: Authenticator,
) -> APIRouter:
    router = APIRouter(prefix="/api", dependencies=[Depends(authenticator)])

    @router.get("/system")
    async def system(request: Request):
        snap = system_info.snapshot(settings, config_path=settings.config_path)

        # --- how this particular client is reaching us ----------------------
        # Reported back because it's the fastest way to explain a class of
        # confusing failures: a request that arrives looking like 127.0.0.1
        # means the proxy isn't forwarding the real address, which is what
        # silently breaks LAN-only approval.
        peer = client_ip(request, settings.behind_proxy)
        snap["connection"] = {
            "client_ip": peer,
            "client_is_private": is_private_ip(peer) if peer else None,
            "request_url": str(request.base_url).rstrip("/"),
            "host_header": request.headers.get("host"),
            "scheme": request.url.scheme,
            "http_version": request.scope.get("http_version"),
            "forwarded_for": request.headers.get("x-forwarded-for"),
            "behind_proxy_enabled": settings.behind_proxy,
            "user_agent": request.headers.get("user-agent"),
        }

        # --- build identity -------------------------------------------------
        snap["server"]["commit"] = _commit()
        snap["server"]["features"] = FEATURES
        snap["server"]["auth_versions"] = AUTH_VERSIONS
        snap["process"] = _process()

        # --- units ----------------------------------------------------------
        # Capabilities come from the manager's *cache*: a unit that's already
        # connected answers for free, and one that isn't would cost a LAN
        # round-trip each (~0.7 s on real hardware) — too slow to do for every
        # unit while someone waits on a diagnostics screen. Clients that want
        # the rest can ask /api/units/{id}/capabilities per unit.
        units: List[Dict[str, Any]] = []
        for unit in manager.known_units():
            device = manager.cached(unit.unit_id)
            entry: Dict[str, Any] = {
                "id": unit.unit_id,
                "name": unit.name,
                "ip": unit.ip,
                "port": unit.port,
                "has_v3_credentials": bool(unit.token and unit.key),
                "connected": device is not None,
                "capabilities": None,
                "samples": len(history.samples(unit.unit_id)),
            }
            if device is not None:
                try:
                    entry["capabilities"] = serialize_capabilities(unit, device)
                    entry["online"] = bool(getattr(device, "online", True))
                except Exception:
                    pass
            units.append(entry)
        snap["units"] = units

        # --- enrolled devices (the "users") ----------------------------------
        now = time.time()
        devices = []
        for d in token_store.list():
            expires: Optional[float] = d.expires_at
            devices.append({
                "token_id": d.token_id,
                "label": d.label,
                "auth_version": d.auth_version,
                "created_at": d.created_at,
                "last_used": d.last_used,
                "expires_at": expires,
                "expires_in_seconds": (expires - now) if expires else None,
                "expired": bool(expires and expires <= now),
            })
        snap["devices"] = devices

        # --- programs + scheduler --------------------------------------------
        programs = program_store.list()
        kinds: Dict[str, int] = {}
        for p in programs:
            kind = getattr(p, "kind", None) or (p.get("kind") if isinstance(p, dict) else None)
            if kind:
                kinds[kind] = kinds.get(kind, 0) + 1
        snap["programs"] = {"total": len(programs), "by_kind": kinds}
        try:
            snap["scheduler"] = scheduler.status()
        except Exception:
            snap["scheduler"] = None

        # --- on-disk state ----------------------------------------------------
        snap["storage"] = {
            "config": _file_facts(settings.config_path),
            "devices": _file_facts(settings.devices_path),
            "programs": _file_facts(settings.programs_path),
        }
        return snap

    return router
