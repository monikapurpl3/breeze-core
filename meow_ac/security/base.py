"""
The authentication seam.

An `Authenticator` is any object usable as a FastAPI dependency that
raises `HTTPException(401)` when a request is not authorized and returns
normally when it is. The API router depends on one instance (see
`meow_ac.app.create_app`), so swapping or layering auth schemes is a
wiring change in the factory, never an edit to the endpoints.

Authenticators take the `Request` and read whatever they need off it
(headers, client IP, ...). That uniform signature is what lets
`CompositeAuthenticator` run several in sequence by simply calling one
after another — see `security/composite.py`. The shipped composition is
API key + per-device token; adding a further factor (a TOTP check, an IP
allowlist) means writing another class with this signature and appending
it to the list in `create_app()`.
"""
from __future__ import annotations

from typing import Protocol, runtime_checkable

from fastapi import Request


@runtime_checkable
class Authenticator(Protocol):
    """A callable FastAPI dependency that authorizes a request.

    Reads what it needs off the `Request`, raises
    `fastapi.HTTPException(401)` to reject, and returns `None` to accept.
    """

    async def __call__(self, request: Request) -> None: ...
