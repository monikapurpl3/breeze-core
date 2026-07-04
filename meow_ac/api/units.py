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
