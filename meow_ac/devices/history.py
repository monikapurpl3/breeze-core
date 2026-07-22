"""
In-memory per-unit state history.

A small ring buffer of recent readings (indoor/outdoor/target/mode/power) per
unit, filled opportunistically whenever a state is read (the state and batch
routes) — no extra LAN polling of its own. Powers `GET
/api/units/{id}/history` (a client-side graph) and the last-known values in
`GET /metrics`.

Deliberately in-memory and best-effort: it's an activity/telemetry hint, not
a durable record, so a restart simply starts the graph over. Bounded per
unit (`AC_HISTORY_SIZE`, default 720 samples ≈ an hour at the 5 s app poll).
"""
from __future__ import annotations

import time
from collections import deque
from typing import Deque, Dict, List, Optional


class HistoryBuffer:
    def __init__(self, size: int = 720):
        self._size = max(1, size)
        self._by_unit: Dict[str, Deque[dict]] = {}

    def record(self, state: dict) -> None:
        """Append a compact sample from a serialized unit state dict."""
        uid = state.get("id")
        if uid is None:
            return
        buf = self._by_unit.get(uid)
        if buf is None:
            buf = self._by_unit[uid] = deque(maxlen=self._size)
        buf.append({
            "t": int(time.time()),
            "online": state.get("online"),
            "power_state": state.get("power_state"),
            "operational_mode": state.get("operational_mode"),
            "target_temperature": state.get("target_temperature"),
            "indoor_temperature": state.get("indoor_temperature"),
            "outdoor_temperature": state.get("outdoor_temperature"),
        })

    def samples(self, unit_id: str) -> List[dict]:
        return list(self._by_unit.get(unit_id, ()))

    def latest(self, unit_id: str) -> Optional[dict]:
        buf = self._by_unit.get(unit_id)
        return buf[-1] if buf else None
