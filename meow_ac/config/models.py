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

from pydantic import BaseModel, Field, model_validator


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
    """One enrolled client device.

    The stored credential depends on `auth_version`:

    - **v1 (bearer)** — `token_hash` holds the SHA-256 hash of a random
      bearer token shown to the client once at enrollment; the token itself
      is never stored. This is the original scheme; existing records load as
      v1 because `auth_version` defaults to 1.
    - **v2 (Ed25519)** — `public_key` holds the device's Ed25519 public key
      (URL-safe base64 of 32 raw bytes). The server stores *only* the public
      key; the private key never leaves the device, and there is no secret at
      rest to leak. Requests are signed (see `security/signing.py`).

    A device is pinned to its version: a v1 record can only be matched by a
    bearer token, a v2 record only by a valid signature. `token_hash` and
    `public_key` are therefore mutually exclusive per record.

    Times are epoch seconds; `expires_at` None means non-expiring.
    """

    token_id: str
    label: str
    auth_version: int = 1
    token_hash: Optional[str] = None   # v1 only
    public_key: Optional[str] = None   # v2 only (Ed25519, b64url raw)
    created_at: float
    expires_at: Optional[float] = None
    last_used: Optional[float] = None

    @model_validator(mode="after")
    def _check_credential(self) -> "DeviceRecord":
        if self.auth_version == 1 and not self.token_hash:
            raise ValueError("v1 device record requires token_hash")
        if self.auth_version == 2 and not self.public_key:
            raise ValueError("v2 device record requires public_key")
        return self


class DevicesDoc(BaseModel):
    """The devices.json document — enrolled tokens, written at runtime by
    the app (kept separate from the admin-managed config.json)."""

    devices: List[DeviceRecord] = Field(default_factory=list)
