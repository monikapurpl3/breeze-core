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

from meow_ac.security import net
from meow_ac.security.base import Authenticator
from meow_ac.security.enrollment import APPROVED, EnrollmentService, PENDING
from meow_ac.security.ratelimit import RateLimiter
from meow_ac.security.token_store import TokenStore
from meow_ac.settings import Settings

log = logging.getLogger("meow-ac")


class StartRequest(BaseModel):
    label: str = Field(default="", max_length=64)


class PollRequest(BaseModel):
    session_id: str = Field(max_length=128)


class ApproveRequest(BaseModel):
    code: str = Field(max_length=32)


def build_auth_router(
    token_store: TokenStore,
    enrollment: EnrollmentService,
    settings: Settings,
    api_key_auth: Authenticator,
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
        session_id, user_code, expires_in = enrollment.start(req.label)
        log.info("enrollment started (label=%r) from %s", req.label, _client_key(request))
        return {"session_id": session_id, "user_code": user_code, "expires_in": expires_in}

    @router.post("/enroll/poll", dependencies=[Depends(api_key_auth)])
    async def enroll_poll(req: PollRequest, request: Request):
        _limit(poll_limit, request)
        status, token, record = enrollment.poll(req.session_id)
        if status == APPROVED and token and record:
            log.info("device enrolled: %s (%s)", record.label, record.token_id)
            return {
                "status": APPROVED,
                "device_token": token,
                "token_id": record.token_id,
                "label": record.label,
                "expires_at": record.expires_at,
            }
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

    @router.get("/devices", dependencies=[Depends(api_key_auth), Depends(require_lan)])
    async def list_devices():
        return [
            {
                "token_id": d.token_id,
                "label": d.label,
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
