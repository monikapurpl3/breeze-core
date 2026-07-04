"""
DeviceManager — owns every live connection to a physical unit.

This is the former module-level `_devices` / `_units_cfg` / `_locks`
globals reworked into one object. Behavior is unchanged:

- connections are lazy and cached per unit id; the first request pays
  connect + authenticate (V3) + get_capabilities + refresh, subsequent
  ones reuse the object,
- each unit has its own asyncio.Lock so concurrent requests to the same
  unit serialize,
- every read/write is still a live LAN round-trip.

Holding a reference to the ConfigStore (rather than a snapshot of the
unit list) means a future runtime `store.reload()` is enough for the
manager to see newly added units — and `forget()` is here so re-pairing
or removing a unit can drop its stale cached connection.
"""
from __future__ import annotations

import asyncio
import logging
from typing import Dict, List, Optional

from fastapi import HTTPException

from msmart.device import AirConditioner as AC

from meow_ac.config.models import UnitConfig
from meow_ac.config.store import ConfigStore

log = logging.getLogger("meow-ac")


class DeviceManager:
    def __init__(self, store: ConfigStore):
        self._store = store
        self._devices: Dict[str, AC] = {}
        self._locks: Dict[str, asyncio.Lock] = {}

    def known_units(self) -> List[UnitConfig]:
        """Units from config, no device contact."""
        return list(self._store.config.units)

    def unit_config(self, unit_id: str) -> Optional[UnitConfig]:
        return self._store.find_unit(unit_id)

    def lock_for(self, unit_id: str) -> asyncio.Lock:
        """Per-unit lock, created on first use."""
        if unit_id not in self._locks:
            self._locks[unit_id] = asyncio.Lock()
        return self._locks[unit_id]

    async def get(self, unit_id: str) -> AC:
        """Return a connected AC for the unit, connecting on first use.

        Raises HTTPException(404) for an unknown unit id — the caller is
        expected to let that propagate (it must not be turned into a
        503).
        """
        unit = self._store.find_unit(unit_id)
        if unit is None:
            raise HTTPException(404, f"Unknown unit '{unit_id}'")

        if unit_id in self._devices:
            return self._devices[unit_id]

        device = AC(ip=unit.ip, port=unit.port, device_id=int(unit.id))

        if unit.token and unit.key:
            await device.authenticate(unit.token, unit.key)

        await device.get_capabilities()
        await device.refresh()

        self._devices[unit_id] = device
        log.info("Connected to unit %s (%s) at %s", unit_id, unit.name, unit.ip)
        return device

    def forget(self, unit_id: str) -> None:
        """Drop the cached connection for a unit (e.g. after re-pairing),
        so the next request reconnects with fresh config."""
        self._devices.pop(unit_id, None)
