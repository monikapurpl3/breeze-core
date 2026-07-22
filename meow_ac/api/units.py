"""
The /api/units router.

Built by a factory so its collaborators (the DeviceManager and the
authenticator) are injected rather than reached for as globals — that's
what makes the app testable and lets `create_app()` decide the auth
scheme. Adding a new resource (say, POST /api/units for add-from-UI, or
an /api/auth router for login) means writing another `build_*` factory
and including it in `create_app()`; this file stays about units.
"""
from __future__ import annotations

import asyncio
import logging

from fastapi import APIRouter, Depends, HTTPException, Query

from meow_ac.devices import discovery
from meow_ac.devices.control import apply_to_unit
from meow_ac.devices.history import HistoryBuffer
from meow_ac.devices.manager import DeviceManager
from meow_ac.devices.schemas import ControlRequest, serialize, serialize_capabilities
from meow_ac.security.base import Authenticator

log = logging.getLogger("meow-ac")


def build_router(
    manager: DeviceManager,
    authenticator: Authenticator,
    history: HistoryBuffer,
) -> APIRouter:
    # Auth is applied to the whole router, so every /api/* route is
    # protected by construction — you can't forget it on a new endpoint.
    router = APIRouter(prefix="/api", dependencies=[Depends(authenticator)])

    # Serialize scans: a scan is a burst of hundreds of connects, and two at
    # once just doubles the load for no benefit.
    scan_lock = asyncio.Lock()

    @router.get("/units")
    async def list_units():
        return [
            {"id": u.unit_id, "name": u.name, "ip": u.ip}
            for u in manager.known_units()
        ]

    @router.get("/units/state")
    async def all_states():
        """Every unit's state in one call, fanned out concurrently.

        Each unit keeps its own lock, so this parallelizes the (inherently
        per-unit, live) LAN round-trips instead of the client paying them
        one at a time. Partial failure is expected and non-fatal: a unit
        that can't be reached lands in `errors`, the rest still come back
        in `states`. Shape is intentionally an envelope so a single
        unreachable unit never 503s the whole batch.
        """
        async def _one(unit):
            unit_id = unit.unit_id
            async with manager.lock_for(unit_id):
                try:
                    device = await manager.get(unit_id)
                    await device.refresh()
                    state = serialize(manager.unit_config(unit_id), device)
                    history.record(state)
                    return ("ok", state)
                except Exception:
                    log.warning("batch refresh failed for %s", unit_id)
                    return ("err", {"id": unit_id, "name": unit.name, "ip": unit.ip,
                                    "detail": "couldn't reach that unit"})

        results = await asyncio.gather(*[_one(u) for u in manager.known_units()])
        states = [r[1] for r in results if r[0] == "ok"]
        errors = [r[1] for r in results if r[0] == "err"]
        return {"states": states, "errors": errors}

    @router.get("/units/scan")
    async def scan_units(
        subnet: str = Query(default="", description="CIDR to scan; default: the server's private /24"),
        timeout: float = Query(default=0.4, ge=0.1, le=3.0),
    ):
        """Scan the LAN for hosts with a Midea port (6440–6449) open, so a
        client can offer 'pick from found units' next to manual IP entry.
        Read-only: it finds candidates; adding one still goes through
        POST /api/units (which runs real discovery). Candidates already in
        the config are flagged `known`."""
        target = subnet or discovery.local_private_subnet()
        if not target:
            raise HTTPException(
                400,
                "couldn't determine the LAN subnet automatically — pass ?subnet=192.168.1.0/24",
            )
        if scan_lock.locked():
            raise HTTPException(409, "a scan is already in progress")
        async with scan_lock:
            try:
                found = await discovery.scan_subnet(target, timeout=timeout)
            except ValueError as e:
                raise HTTPException(400, str(e))
            except Exception:
                log.exception("scan failed for %s", target)
                raise HTTPException(503, "scan failed")

        known_ips = {u.ip for u in manager.known_units()}
        candidates = [
            {"ip": ip, "port": port, "known": ip in known_ips}
            for ip, port in sorted(found.items(), key=lambda kv: tuple(int(o) for o in kv[0].split(".")))
        ]
        return {"subnet": target, "candidates": candidates}

    @router.get("/units/{unit_id}/state")
    async def unit_state(unit_id: str):
        async with manager.lock_for(unit_id):
            try:
                device = await manager.get(unit_id)
                await device.refresh()
            except HTTPException:
                raise
            except Exception:
                log.exception("refresh failed for %s", unit_id)
                raise HTTPException(503, "couldn't reach that unit")
            state = serialize(manager.unit_config(unit_id), device)
            history.record(state)
            return state

    @router.get("/units/{unit_id}/capabilities")
    async def unit_capabilities(unit_id: str):
        """What the unit's firmware actually supports (modes, flap axes,
        eco/turbo, temp range, …) so clients can hide controls it lacks."""
        async with manager.lock_for(unit_id):
            try:
                device = await manager.get(unit_id)
            except HTTPException:
                raise
            except Exception:
                log.exception("capabilities fetch failed for %s", unit_id)
                raise HTTPException(503, "couldn't reach that unit")
            return serialize_capabilities(manager.unit_config(unit_id), device)

    @router.get("/units/{unit_id}/history")
    async def unit_history(unit_id: str):
        """Recent in-memory readings for this unit (for a client-side graph).
        Best-effort and non-persistent — empty until the unit's been polled."""
        if manager.unit_config(unit_id) is None:
            raise HTTPException(404, f"no unit '{unit_id}'")
        return {"id": unit_id, "samples": history.samples(unit_id)}

    @router.post("/units/{unit_id}/control")
    async def unit_control(unit_id: str, req: ControlRequest):
        # Shared with the scheduler — see devices/control.py.
        return await apply_to_unit(manager, unit_id, req)

    return router
