"""
Device-token authentication — the per-device second credential.

Verifies the `Authorization: Bearer <token>` header against the hashed
tokens in the TokenStore. Combined with the API key (see
`CompositeAuthenticator`), this is what gates full API access after a
client has enrolled.
"""
from __future__ import annotations

from fastapi import HTTPException, Request

from meow_ac.security.token_store import TokenStore


def _bearer(request: Request) -> str:
    header = request.headers.get("authorization", "")
    scheme, _, token = header.partition(" ")
    if scheme.lower() != "bearer":
        return ""
    return token.strip()


class DeviceTokenAuthenticator:
    """Authorizes requests bearing a valid, unexpired device token."""

    def __init__(self, token_store: TokenStore):
        self._tokens = token_store

    async def __call__(self, request: Request) -> None:
        token = _bearer(request)
        record = self._tokens.find_by_secret(token) if token else None
        if record is None:
            raise HTTPException(
                401,
                "missing, invalid, or expired device token — enroll this "
                "device to get one",
            )
        self._tokens.touch(record.token_id)
