"""
The /api/timers router — one-shot "do this in N minutes" timers.

Requires full auth (API key + device credential), the same bar as controlling a
unit: a timer *is* a control command, just a deferred one.

Every response carries `seconds_remaining`, computed from the server's clock. A
client should count down from that rather than parsing `fires_at` against its own
clock — the phone's idea of the time is exactly what this design avoids relying on.
"""
from __future__ import annotations

import logging
from datetime import datetime
from typing import Any, Dict, List

from fastapi import APIRouter, Depends, HTTPException

from meow_ac.devices.manager import DeviceManager
from meow_ac.security.base import Authenticator
from meow_ac.timers.models import Timer, TimerRequest
from meow_ac.timers.runner import TimerRunner
from meow_ac.timers.store import TimerStore

log = logging.getLogger("meow-ac")


def build_timers_router(
    manager: DeviceManager,
    store: TimerStore,
    runner: TimerRunner,
    auth: Authenticator,
) -> APIRouter:
    router = APIRouter(prefix="/api/timers", dependencies=[Depends(auth)])

    def _serialize(timer: Timer, now: datetime) -> Dict[str, Any]:
        data = timer.model_dump()
        # Only the fields the timer will actually apply. A ControlRequest dump is
        # mostly nulls, and a client rendering "what happens when this fires"
        # should not have to filter them out.
        data["settings"] = timer.settings.model_dump(exclude_none=True)
        data["seconds_remaining"] = timer.seconds_remaining(now)
        return data

    # Static route BEFORE "/{timer_id}", or it is captured as an id.
    @router.get("/status")
    async def timer_status():
        return runner.status()

    @router.get("")
    async def list_timers() -> List[Dict[str, Any]]:
        now = datetime.now()
        return [_serialize(t, now) for t in store.list()]

    @router.post("", status_code=201)
    async def create_timer(req: TimerRequest) -> Dict[str, Any]:
        known = {u.unit_id for u in manager.known_units()}
        unknown = [uid for uid in req.unit_ids if uid not in known]
        if unknown:
            # Same shape as the control route's unknown-unit error, so clients
            # already handle it.
            raise HTTPException(404, f"unknown unit(s): {', '.join(unknown)}")

        # One timer per unit, deliberately: asking for "off in 30" on a unit that
        # already has a timer means you changed your mind, not that you want two
        # competing promises about the same unit. Replacing is what every phone
        # sleep timer does.
        replaced = 0
        for uid in req.unit_ids:
            for existing in store.for_unit(uid):
                if store.delete(existing.id):
                    replaced += 1

        timer = store.add(req)
        log.info(
            "timer %s created: %s in %d min%s",
            timer.id, ", ".join(timer.unit_ids) or "all units", timer.minutes,
            f" (replaced {replaced})" if replaced else "",
        )
        return _serialize(timer, datetime.now())

    @router.delete("/{timer_id}", status_code=204)
    async def delete_timer(timer_id: str):
        if not store.delete(timer_id):
            raise HTTPException(404, "no such timer")
        log.info("timer %s cancelled", timer_id)
        return None

    return router
