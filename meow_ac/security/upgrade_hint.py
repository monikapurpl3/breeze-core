"""
UpgradeHintMiddleware — the soft-rollout nudge.

When a request authenticated with an *older* device auth-version than the
server's newest supported one, the response carries:

    X-Breeze-Upgrade: auth-version=<newest>

The device authenticator records the version it accepted on
`request.state.auth_version`; this middleware turns a below-newest value into
that advisory header. It changes nothing about whether the request succeeds —
that's the `min_auth_version` clamp's job — it only signals "a better profile
is available", which an up-to-date client uses to trigger its seamless
in-place upgrade (POST /api/auth/upgrade). Requests that didn't authenticate a
device (enrollment, health, static) have no `auth_version` and get no header.
"""
from __future__ import annotations

from starlette.middleware.base import BaseHTTPMiddleware

# Newest device auth-version this build offers (kept in step with
# meta.AUTH_VERSIONS). A client on anything below this is nudged.
NEWEST_AUTH_VERSION = 2


class UpgradeHintMiddleware(BaseHTTPMiddleware):
    async def dispatch(self, request, call_next):
        response = await call_next(request)
        used = getattr(request.state, "auth_version", None)
        if isinstance(used, int) and used < NEWEST_AUTH_VERSION:
            response.headers.setdefault(
                "X-Breeze-Upgrade", f"auth-version={NEWEST_AUTH_VERSION}"
            )
        return response
