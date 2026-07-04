"""
LAN discovery + pairing, decoupled from the setup CLI.

setup_device.py is just the command-line front end for these functions;
keeping the msmart-ng discovery calls here means a future "scan for new
units" button in the web UI can reuse the exact same code path (call
`discover_all()`, turn each result into a `UnitConfig` via `to_unit`,
hand it to `ConfigStore.add_or_update_unit`).
"""
from __future__ import annotations

from typing import List

from msmart.discover import Discover

from meow_ac.config.models import UnitConfig


async def discover_all() -> list:
    """Broadcast on the LAN and return every unit that answers."""
    return await Discover.discover()


async def discover_one(ip: str) -> List:
    """Probe a single known IP; returns a 0- or 1-element list so callers
    can treat it the same as `discover_all()`."""
    device = await Discover.discover_single(ip)
    return [device] if device else []


def to_unit(device, name: str) -> UnitConfig:
    """Turn a discovered msmart device into a storable UnitConfig."""
    return UnitConfig(
        name=name,
        ip=device.ip,
        port=getattr(device, "port", 6444),
        id=device.id,
        token=getattr(device, "token", None),
        key=getattr(device, "key", None),
    )
