"""
TimerRunner — fires one-shot timers and deletes them.

Its own asyncio task rather than a branch inside the programs Scheduler, for two
reasons that are not stylistic:

* **Tick rate.** A timer is a promise about a moment ("off in 45 minutes"), so it
  ticks every 15s by default; the scheduler's 30s minute-matching is right for
  "every Tuesday at 07:00" and coarse for this.
* **Failure isolation.** A timer that fires deletes itself, which means it writes
  to disk on the hot path. If that write throws — a full disk, a wrong owner after
  a botched upgrade — the fault is contained here instead of stopping schedules
  and curves from running.

Both loops go through the same `apply_to_unit` as the HTTP control route, so a
timer firing is indistinguishable from a person pressing the button, including on
the SSE stream.
"""
from __future__ import annotations

import asyncio
import logging
from datetime import datetime
from typing import List, Optional

from meow_ac.devices.control import apply_to_unit
from meow_ac.devices.manager import DeviceManager
from meow_ac.timers.models import Timer
from meow_ac.timers.store import TimerStore

log = logging.getLogger("meow-ac")


class TimerRunner:
    def __init__(self, manager: DeviceManager, store: TimerStore, tick_seconds: int = 15):
        self._manager = manager
        self._store = store
        self._tick = max(1, tick_seconds)
        self._task: Optional[asyncio.Task] = None
        self.runs = 0
        self.fired = 0
        self.errors = 0
        self.last_run_iso: Optional[str] = None

    async def start(self) -> None:
        if self._task is None:
            self._task = asyncio.create_task(self._loop())
            log.info("timer runner started (tick=%ss)", self._tick)

    async def stop(self) -> None:
        if self._task:
            self._task.cancel()
            try:
                await self._task
            except asyncio.CancelledError:
                pass
            self._task = None
            log.info("timer runner stopped")

    async def _loop(self) -> None:
        while True:
            try:
                await self.run_once(datetime.now())
            except asyncio.CancelledError:
                raise
            except Exception:
                self.errors += 1
                log.exception("timer tick failed")
            await asyncio.sleep(self._tick)

    async def run_once(self, now: Optional[datetime] = None) -> List[Timer]:
        """Fire every due timer and remove it. Returns what fired."""
        now = now or datetime.now()
        self.runs += 1
        self.last_run_iso = now.isoformat(timespec="seconds")

        due = [t for t in self._store.list() if t.is_due(now)]
        if not due:
            return []

        for timer in due:
            # An overdue timer still fires. If the server was asleep or down when
            # it came due, "off, late" is the safe direction to be wrong in --
            # unlike skipping it, which leaves a unit running all night because
            # the machine rebooted. It is logged so it is not a mystery.
            late = -timer.seconds_remaining(now)
            if late > 120:
                log.info(
                    "timer %s was due %ds ago (server asleep or restarted?) — firing now",
                    timer.id, late,
                )
            targets = timer.unit_ids or [u.unit_id for u in self._manager.known_units()]
            for uid in targets:
                try:
                    state = await apply_to_unit(self._manager, uid, timer.settings)
                    # "dispatched", not "fired": msmart's apply() does not raise
                    # when a unit is unreachable -- it logs the network error and
                    # returns -- so a 200 from the control path is not proof the
                    # unit heard anything. The serialized state does carry
                    # online=false in that case, and for an unattended action it
                    # is worth saying so in the log rather than implying success.
                    if state.get("online") is False:
                        log.warning(
                            "timer %s dispatched to unit %s, but the unit is "
                            "offline -- it may not have received it", timer.id, uid,
                        )
                    else:
                        log.info("timer %s dispatched to unit %s", timer.id, uid)
                except Exception as e:
                    # A unit that is unreachable right now must not keep the timer
                    # alive: it would retry every tick forever, and by the time the
                    # unit answers the moment the user asked about is long past.
                    log.warning("timer %s -> unit %s failed: %s", timer.id, uid, e)

        self.fired += len(due)
        self._store.delete_many([t.id for t in due])
        return due

    def status(self) -> dict:
        pending = self._store.list()
        return {
            "running": self._task is not None and not self._task.done(),
            "tick_seconds": self._tick,
            "runs": self.runs,
            "fired": self.fired,
            "errors": self.errors,
            "last_run": self.last_run_iso,
            "pending": len(pending),
            "next_fires_at": min((t.fires_at for t in pending), default=None),
        }
