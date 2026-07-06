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

from fastapi import APIRouter, Depends, HTTPException

from meow_ac.devices.control import apply_to_unit
from meow_ac.devices.manager import DeviceManager
from meow_ac.devices.schemas import ControlRequest, serialize
from meow_ac.security.base import Authenticator

log = logging.getLogger("meow-ac")


def build_router(manager: DeviceManager, authenticator: Authenticator) -> APIRouter:
    # Auth is applied to the whole router, so every /api/* route is
    # protected by construction — you can't forget it on a new endpoint.
    router = APIRouter(prefix="/api", dependencies=[Depends(authenticator)])

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
                    return ("ok", serialize(manager.unit_config(unit_id), device))
                except Exception:
                    log.warning("batch refresh failed for %s", unit_id)
                    return ("err", {"id": unit_id, "name": unit.name, "ip": unit.ip,
                                    "detail": "couldn't reach that unit"})

        results = await asyncio.gather(*[_one(u) for u in manager.known_units()])
        states = [r[1] for r in results if r[0] == "ok"]
        errors = [r[1] for r in results if r[0] == "err"]
        return {"states": states, "errors": errors}

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
            return serialize(manager.unit_config(unit_id), device)

    @router.post("/units/{unit_id}/control")
    async def unit_control(unit_id: str, req: ControlRequest):
        # Shared with the scheduler — see devices/control.py.
        return await apply_to_unit(manager, unit_id, req)

    return router
