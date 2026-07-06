"""
The /api config-management router — a secure, authenticated way for a
client to read a sanitized view of the config and to rename / add units.

Requires full auth (API key + device token), same as control. Adding a
unit reuses the shared LAN-discovery code (`devices/discovery.py`), the
exact path `setup_device.py` uses.

**Never** returns the `api_key` or any per-unit V3 `token`/`key` — those
are secrets. Clients get only what they need to manage units.
"""
from __future__ import annotations

import logging
from ipaddress import ip_address
from typing import Optional

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field, field_validator

from meow_ac.config.models import UnitConfig
from meow_ac.config.store import ConfigStore
from meow_ac.devices import discovery
from meow_ac.devices.manager import DeviceManager
from meow_ac.security.base import Authenticator

log = logging.getLogger("meow-ac")


class RenameRequest(BaseModel):
    name: str = Field(min_length=1, max_length=64)


class AddUnitRequest(BaseModel):
    ip: str
    name: Optional[str] = Field(default=None, max_length=64)

    @field_validator("ip")
    @classmethod
    def _valid_ip(cls, v: str) -> str:
        v = v.strip()
        ip_address(v)  # raises ValueError → 422 for anything that isn't an IP
        return v


def _unit_view(u: UnitConfig) -> dict:
    """A safe, secret-free view of a unit."""
    return {
        "id": u.unit_id,
        "name": u.name,
        "ip": u.ip,
        "port": u.port,
        "has_v3_credentials": bool(u.token and u.key),
    }


def build_config_router(
    store: ConfigStore,
    manager: DeviceManager,
    auth: Authenticator,
) -> APIRouter:
    router = APIRouter(prefix="/api", dependencies=[Depends(auth)])

    @router.get("/config")
    async def get_config():
        """Sanitized config — units only, never the API key or V3 secrets."""
        return {"units": [_unit_view(u) for u in store.config.units]}

    @router.patch("/units/{unit_id}")
    async def rename_unit(unit_id: str, req: RenameRequest):
        unit = store.find_unit(unit_id)
        if unit is None:
            raise HTTPException(404, f"Unknown unit '{unit_id}'")
        unit.name = req.name
        store.save()
        log.info("unit %s renamed to %r", unit_id, req.name)
        return _unit_view(unit)

    @router.post("/units", status_code=201)
    async def add_unit(req: AddUnitRequest):
        """Discover the Midea unit at `ip` on the LAN and add it to config."""
        try:
            found = await discovery.discover_one(req.ip)
        except Exception:
            log.exception("discovery failed for %s", req.ip)
            raise HTTPException(503, "discovery failed — could not probe that address")

        devices = [d for d in found if getattr(d, "supported", True)]
        if not devices:
            raise HTTPException(404, f"no supported Midea unit found at {req.ip}")

        device = devices[0]
        existing = store.find_unit(str(device.id))
        name = req.name or (existing.name if existing else None) or f"AC {device.ip}"
        unit = discovery.to_unit(device, name)
        store.add_or_update_unit(unit)
        store.save()
        manager.forget(unit.unit_id)  # drop any stale cached connection
        log.info("unit added/updated via IP %s: %s (%s)", req.ip, unit.name, unit.unit_id)
        return _unit_view(unit)

    @router.delete("/units/{unit_id}", status_code=204)
    async def delete_unit(unit_id: str):
        """Remove a unit from config. Drops its cached connection too."""
        if store.find_unit(unit_id) is None:
            raise HTTPException(404, f"Unknown unit '{unit_id}'")
        store.remove_unit(unit_id)
        store.save()
        manager.forget(unit_id)
        log.info("unit %s removed", unit_id)
        # 204 No Content — return nothing.

    return router
