"""
Live state push over Server-Sent Events (SSE).

Midea units have no push — the server must poll them — so this doesn't remove
polling, it *centralises* it: one background task refreshes every unit and
fans changes out to all connected SSE clients, instead of each client (app,
web UI, widgets) polling on its own. The phone's radio stops polling
(battery), and a change made elsewhere (a schedule firing, another client)
reaches every stream on the next tick.

The poller is lazy: it sleeps while nobody is subscribed and only hits the
LAN once at least one client is streaming. Each subscriber is an
`asyncio.Queue`; the loop enqueues a `("state", <serialized>)` event for a
unit whenever its serialized state changes (plus it feeds the HistoryBuffer).
The API layer turns queue items into `text/event-stream` frames.
"""
from __future__ import annotations

import asyncio
import json
import logging
from typing import Dict, List, Optional, Set, Tuple

from meow_ac.devices.manager import DeviceManager
from meow_ac.devices.history import HistoryBuffer
from meow_ac.devices.schemas import serialize

log = logging.getLogger("meow-ac")

Event = Tuple[str, dict]  # (event_type, data)


class StateStream:
    def __init__(self, manager: DeviceManager, history: HistoryBuffer, tick_seconds: float = 5.0):
        self._manager = manager
        self._history = history
        self._tick = max(1.0, float(tick_seconds))
        self._subs: Set[asyncio.Queue] = set()
        self._last_json: Dict[str, str] = {}   # unit_id -> last serialized json (change detection)
        self._last_state: Dict[str, dict] = {}  # unit_id -> last full state (for new-subscriber snapshot)
        self._wake = asyncio.Event()
        self._task: Optional[asyncio.Task] = None

    # -- subscription -------------------------------------------------

    def subscribe(self) -> asyncio.Queue:
        q: asyncio.Queue = asyncio.Queue(maxsize=200)
        self._subs.add(q)
        self._wake.set()  # nudge the idle poller awake
        return q

    def unsubscribe(self, q: asyncio.Queue) -> None:
        self._subs.discard(q)

    def snapshot(self) -> List[Event]:
        """Last-known state for every unit, for a client that just connected
        (so it doesn't wait a whole tick for its first data)."""
        return [("state", s) for s in self._last_state.values()]

    # -- lifecycle ----------------------------------------------------

    async def start(self) -> None:
        if self._task is None:
            self._task = asyncio.create_task(self._run())

    async def stop(self) -> None:
        if self._task is not None:
            self._task.cancel()
            try:
                await self._task
            except (asyncio.CancelledError, Exception):
                pass
            self._task = None

    # -- poller -------------------------------------------------------

    async def _run(self) -> None:
        while True:
            if not self._subs:
                self._wake.clear()
                await self._wake.wait()   # idle until someone subscribes
                continue
            try:
                await self._poll_once()
            except Exception:
                log.exception("stream poll failed")
            await asyncio.sleep(self._tick)

    async def _poll_once(self) -> None:
        for unit in list(self._manager.known_units()):
            uid = unit.unit_id
            async with self._manager.lock_for(uid):
                try:
                    device = await self._manager.get(uid)
                    await device.refresh()
                    state = serialize(self._manager.unit_config(uid), device)
                except Exception:
                    prev = self._last_state.get(uid)
                    state = {**prev, "online": False} if prev else {
                        "id": uid, "name": unit.name, "ip": unit.ip, "online": False,
                        "power_state": False, "operational_mode": "AUTO",
                        "target_temperature": 22.0, "indoor_temperature": None,
                        "outdoor_temperature": None, "fan_speed": 102,
                        "swing_mode": "OFF", "eco": False, "turbo": False,
                    }
            self._history.record(state)
            key = json.dumps(state, sort_keys=True)
            if self._last_json.get(uid) != key:
                self._last_json[uid] = key
                self._last_state[uid] = state
                self._broadcast(("state", state))

    def _broadcast(self, event: Event) -> None:
        for q in list(self._subs):
            try:
                q.put_nowait(event)
            except asyncio.QueueFull:
                # A slow/stuck client: drop rather than block the poller or
                # every other client. It'll catch up on the next change.
                pass
