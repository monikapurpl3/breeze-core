"""
CompositeAuthenticator — require several authenticators to all pass.

This is the "improve on the idea" glue: full API access requires the
API key *and* a per-device token, so the router depends on
`CompositeAuthenticator([api_key_auth, device_token_auth])`. Each
sub-authenticator reads what it needs off the Request and raises
HTTPException(401) to reject; the composite just runs them in order and
lets the first failure propagate.

Adding another factor later (a TOTP check, an IP allowlist) is a matter
of appending it to the list in `create_app()` — no endpoint changes.
"""
from __future__ import annotations

from typing import Sequence

from fastapi import Request

from meow_ac.security.base import Authenticator


class CompositeAuthenticator:
    def __init__(self, authenticators: Sequence[Authenticator]):
        self._authenticators = list(authenticators)

    async def __call__(self, request: Request) -> None:
        for authenticator in self._authenticators:
            await authenticator(request)
