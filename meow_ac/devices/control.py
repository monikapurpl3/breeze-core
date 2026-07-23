"""
Applying a control payload to a unit — shared by the HTTP control route
and the background scheduler.

Extracted so `api/units.py` (a user pressing a button) and
`programs/scheduler.py` (a schedule/curve firing) run the *exact same*
code path: same locking, same enum handling, same beep policy (client
opt-in, silent by default), same error semantics. The function raises `HTTPException` (400 bad enum, 404
unknown unit, 503 unreachable/apply-failed); the API route lets those
propagate, the scheduler catches them broadly and logs.
"""
from __future__ import annotations

import logging

from fastapi import HTTPException

from msmart.device import AirConditioner as AC

from meow_ac.devices.manager import DeviceManager
from meow_ac.devices.schemas import ControlRequest, serialize

log = logging.getLogger("meow-ac")


async def apply_to_unit(manager: DeviceManager, unit_id: str, req: ControlRequest) -> dict:
    """Apply the fields present in `req` to one unit and return its new state."""
    async with manager.lock_for(unit_id):
        try:
            device = await manager.get(unit_id)
        except HTTPException:
            raise
        except Exception:
            raise HTTPException(503, "couldn't reach that unit")

        if req.power_state is not None:
            device.power_state = req.power_state
        if req.operational_mode is not None:
            try:
                device.operational_mode = AC.OperationalMode[req.operational_mode.upper()]
            except KeyError:
                raise HTTPException(400, f"Unknown mode: {req.operational_mode}")
        if req.target_temperature is not None:
            device.target_temperature = req.target_temperature
        if req.fan_speed is not None:
            device.fan_speed = req.fan_speed
        if req.swing_mode is not None:
            try:
                device.swing_mode = AC.SwingMode[req.swing_mode.upper()]
            except KeyError:
                raise HTTPException(400, f"Unknown swing mode: {req.swing_mode}")
        if req.eco is not None:
            device.eco = req.eco
        if req.turbo is not None:
            device.turbo = req.turbo

        # Beep only if the client explicitly asks for it; default silent so a
        # 2am schedule/curve (or any client that doesn't send `beep`) stays
        # quiet. The Breeze app drives this from a per-device settings toggle.
        device.beep = bool(req.beep) if req.beep is not None else False

        try:
            await device.apply()
        except Exception:
            log.exception("apply failed for %s", unit_id)
            raise HTTPException(503, "couldn't apply settings to that unit")

        return serialize(manager.unit_config(unit_id), device)
