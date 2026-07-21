"""
The /api/auth router — device enrollment and token management.

Endpoints (see README "Authentication" for the full flow):

  POST /api/auth/enroll/start    api-key       → {session_id, user_code, expires_in}
  POST /api/auth/enroll/poll     api-key       → {status[, device_token, ...]}
  POST /api/auth/enroll/approve  api-key + LAN  → {token_id, label}   (admin)
  GET  /api/auth/devices         api-key + LAN  → [{token_id, label, ...}]  (admin)
  DELETE /api/auth/devices/{id}  api-key + LAN  → 204                       (admin)

`start`/`poll` need only the enrollment key, so a not-yet-enrolled client
can bootstrap. `approve` and device management are admin actions: they
require the API key *and* originate from the trusted network (the admin
approves/manages on the LAN). The minted device token is the credential
for the actual control API (see the units router), not for management.
"""
from __future__ import annotations

import logging

from fastapi import APIRouter, Depends, HTTPException, Request
from pydantic import BaseModel, Field

from meow_ac.security import net, signing
from meow_ac.security.base import Authenticator
from meow_ac.security.enrollment import APPROVED, EnrollmentService, PENDING
from meow_ac.security.ratelimit import RateLimiter
from meow_ac.security.token_store import TokenStore
from meow_ac.settings import Settings

log = logging.getLogger("meow-ac")


class StartRequest(BaseModel):
    label: str = Field(default="", max_length=64)
    # auth_version 2 clients supply their Ed25519 public key (b64url, 32 raw
    # bytes) here at the start of enrollment. Omitted / 1 = legacy bearer.
    auth_version: int = Field(default=1, ge=1, le=2)
    public_key: str = Field(default="", max_length=128)


class PollRequest(BaseModel):
    session_id: str = Field(max_length=128)


class ApproveRequest(BaseModel):
    code: str = Field(max_length=32)


class UpgradeRequest(BaseModel):
    # The new Ed25519 public key the already-enrolled device just generated.
    public_key: str = Field(max_length=128)


def build_auth_router(
    token_store: TokenStore,
    enrollment: EnrollmentService,
    settings: Settings,
    api_key_auth: Authenticator,
    device_auth: Authenticator,
) -> APIRouter:
    router = APIRouter(prefix="/api/auth")

    # Backstop rate limits (nginx/fail2ban should be the real ones).
    # Approve is the sensitive one — that's where a code is guessed.
    start_limit = RateLimiter(max_hits=10, window_seconds=60)
    poll_limit = RateLimiter(max_hits=120, window_seconds=60)
    approve_limit = RateLimiter(max_hits=10, window_seconds=60)

    def _client_key(request: Request) -> str:
        return net.client_ip(request, settings.behind_proxy) or "unknown"

    def _limit(limiter: RateLimiter, request: Request) -> None:
        if not limiter.allow(_client_key(request)):
            raise HTTPException(429, "too many requests — slow down")

    async def require_lan(request: Request) -> None:
        """Admin guard: approval and device management must originate from
        the trusted network. Combined with Depends(api_key_auth), this is
        'you hold the API key AND you're on the LAN'."""
        if not settings.enrollment_lan_only:
            return
        ip = net.client_ip(request, settings.behind_proxy)
        if not net.is_private_ip(ip):
            log.warning("admin action rejected: non-LAN client %s", ip)
            raise HTTPException(403, "admin actions are restricted to the local network")

    @router.post("/enroll/start", dependencies=[Depends(api_key_auth)])
    async def enroll_start(req: StartRequest, request: Request):
        _limit(start_limit, request)
        if req.auth_version == 2:
            if not signing.public_key_is_valid(req.public_key):
                raise HTTPException(400, "invalid or missing Ed25519 public_key for auth_version 2")
        session_id, user_code, expires_in = enrollment.start(
            req.label,
            auth_version=req.auth_version,
            public_key=req.public_key or None,
        )
        log.info(
            "enrollment started (label=%r, auth_v=%d) from %s",
            req.label, req.auth_version, _client_key(request),
        )
        return {"session_id": session_id, "user_code": user_code, "expires_in": expires_in}

    @router.post("/enroll/poll", dependencies=[Depends(api_key_auth)])
    async def enroll_poll(req: PollRequest, request: Request):
        _limit(poll_limit, request)
        status, token, record = enrollment.poll(req.session_id)
        if status == APPROVED and record:
            log.info(
                "device enrolled: %s (%s, auth_v=%d)",
                record.label, record.token_id, record.auth_version,
            )
            resp = {
                "status": APPROVED,
                "token_id": record.token_id,
                "label": record.label,
                "auth_version": record.auth_version,
                "expires_at": record.expires_at,
            }
            # v1 only: the bearer token is delivered exactly once, here. v2
            # devices already hold their private key, so there's no secret to
            # return.
            if token:
                resp["device_token"] = token
            return resp
        if status == PENDING:
            return {"status": PENDING}
        # expired or unknown — tell the client to stop and restart
        return {"status": status}

    @router.post("/enroll/approve", dependencies=[Depends(api_key_auth), Depends(require_lan)])
    async def enroll_approve(req: ApproveRequest, request: Request):
        _limit(approve_limit, request)
        record = enrollment.approve(req.code)
        if record is None:
            # generic message — don't reveal whether a code existed
            raise HTTPException(400, "invalid or expired code")
        log.info("enrollment approved: %s (%s)", record.label, record.token_id)
        return {"token_id": record.token_id, "label": record.label}

    @router.post("/upgrade", dependencies=[Depends(api_key_auth), Depends(device_auth)])
    async def upgrade_device(req: UpgradeRequest, request: Request):
        """Migrate the *calling* device from bearer (v1) to Ed25519 (v2) in
        place. Authorized by the device's existing valid credential — no
        admin re-approval and no LAN gate, because this trusts nobody new: it
        only re-keys a device that already proved possession of a working
        credential. The client generates the keypair and sends its public
        key; the old bearer token stops working immediately afterwards.
        """
        _limit(approve_limit, request)
        token_id = getattr(request.state, "device_token_id", None)
        if not token_id:
            raise HTTPException(401, "no authenticated device to upgrade")
        if not signing.public_key_is_valid(req.public_key):
            raise HTTPException(400, "invalid Ed25519 public_key")
        if not token_store.upgrade_to_v2(token_id, req.public_key):
            raise HTTPException(404, "device not found")
        log.info("device upgraded to v2 (Ed25519): %s", token_id)
        return {"token_id": token_id, "auth_version": 2}

    @router.get("/devices", dependencies=[Depends(api_key_auth), Depends(require_lan)])
    async def list_devices():
        return [
            {
                "token_id": d.token_id,
                "label": d.label,
                "auth_version": d.auth_version,
                "created_at": d.created_at,
                "expires_at": d.expires_at,
                "last_used": d.last_used,
            }
            for d in token_store.list()
        ]

    @router.delete("/devices/{token_id}", status_code=204, dependencies=[Depends(api_key_auth), Depends(require_lan)])
    async def revoke_device(token_id: str):
        if not token_store.revoke(token_id):
            raise HTTPException(404, f"no device with token_id '{token_id}'")
        log.info("device revoked: %s", token_id)
        return None

    return router
