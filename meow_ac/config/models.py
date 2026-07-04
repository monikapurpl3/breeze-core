"""
Typed models for config.json.

Using pydantic here (already a FastAPI dependency) gives validation on
load for free and makes the config shape self-documenting. New top-level
config sections — e.g. a `users` list once there's more than one
credential, or per-unit metadata — are added as fields here and flow
through the store, setup script, and API without touching any loader.

The on-disk shape (unchanged, still written by setup_device.py):

    {
      "api_key": "randomly-generated-urlsafe-string",
      "units": [
        {"name": "Living Room", "ip": "...", "port": 6444,
         "id": 123, "token": null, "key": null}
      ]
    }
"""
from __future__ import annotations

from typing import List, Optional

from pydantic import BaseModel, Field


class UnitConfig(BaseModel):
    """One AC unit as stored in config.json."""

    name: str
    ip: str
    port: int = 6444
    id: int
    # V3 auth credentials; null for V1/V2 devices.
    token: Optional[str] = None
    key: Optional[str] = None

    @property
    def unit_id(self) -> str:
        """String form of the device id — the key used everywhere the
        API and clients refer to a unit (URLs, the _devices cache)."""
        return str(self.id)


class AppConfig(BaseModel):
    """The whole config document."""

    api_key: Optional[str] = None
    units: List[UnitConfig] = Field(default_factory=list)


class DeviceRecord(BaseModel):
    """One enrolled client device / access token.

    Only the SHA-256 hash of the token is ever stored — the token itself
    is shown to the client exactly once, at enrollment, and never again.
    Times are epoch seconds; `expires_at` None means non-expiring.
    """

    token_id: str
    label: str
    token_hash: str
    created_at: float
    expires_at: Optional[float] = None
    last_used: Optional[float] = None


class DevicesDoc(BaseModel):
    """The devices.json document — enrolled tokens, written at runtime by
    the app (kept separate from the admin-managed config.json)."""

    devices: List[DeviceRecord] = Field(default_factory=list)
