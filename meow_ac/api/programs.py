"""
The /api/programs router — CRUD for favourites/schedules/curves, plus
"apply now" and a scheduler status probe for the diagnostics screen.

Requires full auth (API key + device token): these are user features, so
any enrolled client manages them; the scheduler itself runs server-side.
"""
from __future__ import annotations

import logging
from datetime import datetime

from fastapi import APIRouter, Depends, HTTPException

from meow_ac.devices.control import apply_to_unit
from meow_ac.devices.manager import DeviceManager
from meow_ac.programs.models import Program, ProgramSpec
from meow_ac.programs.scheduler import Scheduler, curve_setpoint
from meow_ac.programs.store import ProgramStore
from meow_ac.security.base import Authenticator

log = logging.getLogger("meow-ac")


def build_programs_router(
    manager: DeviceManager,
    store: ProgramStore,
    scheduler: Scheduler,
    auth: Authenticator,
) -> APIRouter:
    router = APIRouter(prefix="/api/programs", dependencies=[Depends(auth)])

    def _targets(program: Program):
        return program.unit_ids or [u.unit_id for u in manager.known_units()]

    # Static route BEFORE "/{program_id}" so it isn't captured as an id.
    @router.get("/status")
    async def scheduler_status():
        return scheduler.status()

    @router.get("")
    async def list_programs():
        return store.list()

    @router.post("", status_code=201)
    async def create_program(spec: ProgramSpec):
        return store.add(spec)

    @router.get("/{program_id}")
    async def get_program(program_id: str):
        program = store.get(program_id)
        if program is None:
            raise HTTPException(404, f"no program '{program_id}'")
        return program

    @router.put("/{program_id}")
    async def update_program(program_id: str, spec: ProgramSpec):
        program = store.update(program_id, spec)
        if program is None:
            raise HTTPException(404, f"no program '{program_id}'")
        return program

    @router.delete("/{program_id}", status_code=204)
    async def delete_program(program_id: str):
        if not store.delete(program_id):
            raise HTTPException(404, f"no program '{program_id}'")
        return None

    @router.post("/{program_id}/apply")
    async def apply_program(program_id: str):
        """Apply a program's settings to its units right now.

        favourite → its scene; curve → the current interpolated setpoint;
        schedule → 400 (those fire automatically, there's no single scene).
        """
        program = store.get(program_id)
        if program is None:
            raise HTTPException(404, f"no program '{program_id}'")

        if program.kind == "favourite":
            if program.favourite is None:
                raise HTTPException(400, "favourite has no settings")
            req = program.favourite
        elif program.kind == "curve":
            if not program.curve:
                raise HTTPException(400, "curve has no points")
            from meow_ac.devices.schemas import ControlRequest
            temp = curve_setpoint(program.curve.points, datetime.now())
            req = ControlRequest(
                power_state=True,
                operational_mode=program.curve.operational_mode,
                fan_speed=program.curve.fan_speed,
                target_temperature=temp,
            )
        else:
            raise HTTPException(400, "schedule programs fire automatically; nothing to apply")

        results = []
        for uid in _targets(program):
            results.append(await apply_to_unit(manager, uid, req))
        return results

    return router
