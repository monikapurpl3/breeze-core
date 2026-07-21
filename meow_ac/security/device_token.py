"""
Device authentication — the per-device second credential.

Version-aware: a device is pinned to the auth profile it enrolled with, and
this authenticator dispatches on what the request presents.

  * **v1 (bearer)** — `Authorization: Bearer <token>`; verified against the
    stored SHA-256 hash. The original scheme; unchanged.
  * **v2 (Ed25519)** — the `X-Breeze-*` signature headers; verified against
    the device's stored public key over a canonical request string with a
    SHA3-512 body digest (see `security/signing.py`). The secret never rides
    the wire, and each request is single-use (timestamp + nonce).

Combined with the API key (see `CompositeAuthenticator`), this gates full API
access after a client has enrolled.

Rollout control: `min_auth_version` (Settings, `AC_MIN_AUTH_VERSION`) is the
clamp. A device whose `auth_version` is below it is refused with **426 Upgrade
Required** and a human-readable message — which even an un-updated client
surfaces to the user (it passes the server `detail` through). The default is
1, so every existing device keeps working; raise it to 2 once the app upgrade
is widespread. On every accepted request the authenticator records
`request.state.auth_version` so a middleware can add the upgrade-hint header
and the /upgrade route can learn which device is calling.
"""
from __future__ import annotations

from fastapi import HTTPException, Request

from meow_ac.security import signing
from meow_ac.security.signing import NonceCache
from meow_ac.security.token_store import TokenStore


def _bearer(request: Request) -> str:
    header = request.headers.get("authorization", "")
    scheme, _, token = header.partition(" ")
    if scheme.lower() != "bearer":
        return ""
    return token.strip()


def _upgrade_required(min_version: int) -> HTTPException:
    return HTTPException(
        426,
        {
            "error": "auth_upgrade_required",
            "min_auth_version": min_version,
            "detail": (
                "This version of the app uses an outdated, less secure "
                "connection. Please update Breeze to continue controlling "
                "your units."
            ),
        },
    )


class DeviceTokenAuthenticator:
    """Authorizes a request bearing a valid credential for an enrolled device,
    of whichever auth version that device is pinned to."""

    def __init__(
        self,
        token_store: TokenStore,
        nonce_cache: NonceCache,
        min_auth_version: int = 1,
    ):
        self._tokens = token_store
        self._nonces = nonce_cache
        self._min = min_auth_version

    async def __call__(self, request: Request) -> None:
        # A v2 client announces itself with the signature headers; anything
        # else is treated as the legacy bearer scheme.
        if request.headers.get("x-breeze-auth-version") == "2":
            await self._verify_v2(request)
        else:
            await self._verify_v1(request)

    # -- v1: bearer token ---------------------------------------------

    async def _verify_v1(self, request: Request) -> None:
        token = _bearer(request)
        record = self._tokens.find_by_secret(token) if token else None
        if record is None:
            raise HTTPException(
                401,
                "missing, invalid, or expired device token — enroll this "
                "device to get one",
            )
        if record.auth_version < self._min:
            raise _upgrade_required(self._min)
        self._tokens.touch(record.token_id)
        request.state.auth_version = record.auth_version
        request.state.device_token_id = record.token_id

    # -- v2: Ed25519 request signature --------------------------------

    async def _verify_v2(self, request: Request) -> None:
        key_id = request.headers.get("x-breeze-key-id", "")
        timestamp = request.headers.get("x-breeze-timestamp", "")
        nonce = request.headers.get("x-breeze-nonce", "")
        signature = request.headers.get("x-breeze-signature", "")
        if not (key_id and timestamp and nonce and signature):
            raise HTTPException(401, "incomplete request signature")

        record = self._tokens.find_by_key_id(key_id)
        if record is None or not record.public_key:
            raise HTTPException(401, "unknown, expired, or non-v2 device key")

        # (No clamp branch here: v2 already meets any min we'd set. Kept for
        # symmetry if a future v3 raises the floor above 2.)
        if record.auth_version < self._min:
            raise _upgrade_required(self._min)

        now = signing.now_seconds()
        if not self._nonces.timestamp_in_window(timestamp, now):
            raise HTTPException(401, "request timestamp outside the allowed window")

        # Body is cached by Starlette, so reading it here doesn't starve the
        # downstream route handler.
        body = await request.body()
        path = request.url.path
        if request.url.query:
            path = f"{path}?{request.url.query}"
        canonical = signing.build_canonical(request.method, path, timestamp, nonce, body)
        if not signing.verify_signature(record.public_key, canonical, signature):
            raise HTTPException(401, "bad request signature")

        # Verify signature BEFORE spending the nonce, so an attacker can't
        # burn a victim's future nonce with a forged request.
        if not self._nonces.check_and_store(nonce, now):
            raise HTTPException(401, "replayed request (nonce already used)")

        self._tokens.touch(record.token_id)
        request.state.auth_version = record.auth_version
        request.state.device_token_id = record.token_id
