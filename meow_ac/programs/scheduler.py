"""
Scheduler — the background task that fires schedules and drives curves.

One asyncio task in the uvicorn process (the service runs a single
worker, so exactly one scheduler exists). Each tick (default 30s) it
walks the enabled programs and, using the *same* `apply_to_unit` path as
the HTTP control route:

- **schedule**: when the wall clock crosses a trigger's minute (and the
  weekday matches), applies that entry's scene once. A per-(program,
  entry) "last fired minute" guard prevents re-firing within the minute.
- **curve**: computes the interpolated setpoint for "now" (rounded to a
  0.5° step) and applies it — but only when that rounded value *changes*,
  so it isn't a device round-trip every tick, and a manual nudge isn't
  stomped until the curve actually moves to the next step.

All times are server-local. Failures are caught per-program so one bad
unit never kills the loop.
"""
from __future__ import annotations

import asyncio
import logging
from datetime import datetime
from typing import Dict, List, Optional, Tuple

from meow_ac.devices.control import apply_to_unit
from meow_ac.devices.manager import DeviceManager
from meow_ac.devices.schemas import ControlRequest
from meow_ac.programs.models import CurvePoint, Program
from meow_ac.programs.store import ProgramStore

log = logging.getLogger("meow-ac")


def _minutes(hhmm: str) -> int:
    h, m = hhmm.split(":")
    return int(h) * 60 + int(m)


def _round_half(t: float) -> float:
    """Snap to the nearest 0.5°, clamped to the 16–30 range."""
    return max(16.0, min(30.0, round(t * 2) / 2))


def curve_setpoint(points: List[CurvePoint], now: datetime) -> Optional[float]:
    """Interpolated target temperature for `now`, treating the points as a
    cyclic 24h curve. Returns None if there are no points."""
    if not points:
        return None
    pts = sorted(points, key=lambda p: _minutes(p.time))
    if len(pts) == 1:
        return _round_half(pts[0].temperature)
    mins = now.hour * 60 + now.minute
    n = len(pts)
    for i in range(n):
        a, b = pts[i], pts[(i + 1) % n]
        am, bm = _minutes(a.time), _minutes(b.time)
        span = (bm - am) % 1440 or 1440   # wrap across midnight
        off = (mins - am) % 1440
        if off < span:
            frac = off / span
            return _round_half(a.temperature + (b.temperature - a.temperature) * frac)
    return _round_half(pts[0].temperature)


class Scheduler:
    def __init__(self, manager: DeviceManager, store: ProgramStore, tick_seconds: int = 30):
        self._manager = manager
        self._store = store
        self._tick = max(5, tick_seconds)
        self._task: Optional[asyncio.Task] = None
        self._fired: Dict[Tuple[str, int], str] = {}       # (prog, entry) -> "YYYY-MM-DD HH:MM"
        self._curve_applied: Dict[Tuple[str, str], float] = {}  # (prog, unit) -> last temp
        # lightweight status for the diagnostics screen
        self.runs = 0
        self.errors = 0
        self.last_run_iso: Optional[str] = None

    async def start(self) -> None:
        if self._task is None:
            self._task = asyncio.create_task(self._loop())
            log.info("scheduler started (tick=%ss)", self._tick)

    async def stop(self) -> None:
        if self._task:
            self._task.cancel()
            try:
                await self._task
            except asyncio.CancelledError:
                pass
            self._task = None
            log.info("scheduler stopped")

    async def _loop(self) -> None:
        while True:
            try:
                await self.run_once(datetime.now())
            except asyncio.CancelledError:
                raise
            except Exception:
                self.errors += 1
                log.exception("scheduler tick failed")
            await asyncio.sleep(self._tick)

    async def run_once(self, now: datetime) -> None:
        self.runs += 1
        self.last_run_iso = now.isoformat(timespec="seconds")
        for prog in self._store.list():
            if not prog.enabled:
                continue
            targets = prog.unit_ids or [u.unit_id for u in self._manager.known_units()]
            try:
                if prog.kind == "schedule":
                    await self._run_schedule(prog, targets, now)
                elif prog.kind == "curve":
                    await self._run_curve(prog, targets, now)
            except Exception:
                log.exception("program '%s' (%s) failed", prog.name, prog.id)

    async def _run_schedule(self, prog: Program, targets: List[str], now: datetime) -> None:
        stamp = now.strftime("%Y-%m-%d %H:%M")
        hhmm = now.strftime("%H:%M")
        weekday = now.weekday()
        for i, entry in enumerate(prog.schedule):
            if entry.days and weekday not in entry.days:
                continue
            if entry.time != hhmm:
                continue
            key = (prog.id, i)
            if self._fired.get(key) == stamp:
                continue
            self._fired[key] = stamp
            log.info("schedule '%s' firing (%s)", prog.name, hhmm)
            for uid in targets:
                try:
                    await apply_to_unit(self._manager, uid, entry.settings)
                except Exception as e:
                    log.warning("schedule '%s' -> unit %s failed: %s", prog.name, uid, e)

    async def _run_curve(self, prog: Program, targets: List[str], now: datetime) -> None:
        if not prog.curve:
            return
        temp = curve_setpoint(prog.curve.points, now)
        if temp is None:
            return
        req = ControlRequest(
            power_state=True,
            operational_mode=prog.curve.operational_mode,
            fan_speed=prog.curve.fan_speed,
            target_temperature=temp,
        )
        for uid in targets:
            key = (prog.id, uid)
            if self._curve_applied.get(key) == temp:
                continue
            try:
                await apply_to_unit(self._manager, uid, req)
                self._curve_applied[key] = temp
                log.info("curve '%s' -> unit %s set %.1f°", prog.name, uid, temp)
            except Exception as e:
                log.warning("curve '%s' -> unit %s failed: %s", prog.name, uid, e)

    def status(self) -> dict:
        return {
            "running": self._task is not None and not self._task.done(),
            "tick_seconds": self._tick,
            "runs": self.runs,
            "errors": self.errors,
            "last_run": self.last_run_iso,
        }
