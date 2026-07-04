"""
API-key authentication.

In the device-pairing scheme the shared API key is the *enrollment*
secret: on its own it authorizes only the enrollment endpoints. Full
API access additionally requires a per-device token (see
`CompositeAuthenticator` wiring in meow_ac/app.py).

Reads the header off the `Request` directly (rather than via a `Header`
default) so authenticators can be composed by simply calling one after
another — see `security/base.py`.
"""
from __future__ import annotations

import secrets

from fastapi import HTTPException, Request

from meow_ac.config.store import ConfigStore


class ApiKeyAuthenticator:
    """Authorizes requests bearing the correct `X-API-Key` header."""

    def __init__(self, store: ConfigStore):
        self._store = store

    async def __call__(self, request: Request) -> None:
        # ensure_ready() loads the config lazily on the first request and
        # raises with setup guidance if it's missing/incomplete.
        config = self._store.ensure_ready()
        presented = request.headers.get("x-api-key", "")
        # constant-time compare so the key can't be brute-forced via timing
        if not secrets.compare_digest(presented, config.api_key or ""):
            raise HTTPException(401, "missing or invalid X-API-Key header")
