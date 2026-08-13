"""
Authentication logging + machine-readable auth failures.

Two gaps this closes, both learned the hard way from a real incident where
several users were locked out and there was **nothing in the log** to explain
it (uvicorn's access lines showed bare `401 Unauthorized` and no more):

1. **Why** an auth attempt failed is now logged — reason code, which device (by
   key-id prefix only), the client IP and the path. Enough to tell "phone clock
   is off" from "that credential was revoked" without guessing.

2. The reason is also returned to the client as a **stable code**, so a client
   can tell a *transient* failure (clock skew, a replayed nonce) from a
   *definitive* one (unknown or expired credential). The Breeze app used to
   treat every 401 as "my credential is dead", delete its Ed25519 private key,
   and demand re-pairing — which, with LAN-only enrolment, stranded anyone who
   was away from home. A transient 401 must never cost a device its identity.

Never log a secret: no tokens, no signatures, no public keys, and only the
first 8 characters of a key-id (which is a public identifier anyway).
"""
from __future__ import annotations

import logging
from typing import Any, Dict, Optional

from fastapi import HTTPException, Request

log = logging.getLogger("meow-ac.auth")

# --- reason codes -----------------------------------------------------------
# Definitive: the credential itself is no longer usable. A client SHOULD
# re-enroll.
NO_CREDENTIAL = "no_credential"
UNKNOWN_KEY = "unknown_key"
EXPIRED = "expired"
BAD_SIGNATURE = "bad_signature"
BAD_API_KEY = "bad_api_key"

# Transient: the credential is fine, this *request* wasn't. A client SHOULD
# correct and retry, and MUST NOT discard its credential.
CLOCK_SKEW = "clock_skew"
REPLAY = "replay"
INCOMPLETE_SIGNATURE = "incomplete_signature"

#: Reasons a client may safely retry without re-pairing. Sent to the client as
#: `retryable` so even a future client that doesn't know a new code can decide.
RETRYABLE = frozenset({CLOCK_SKEW, REPLAY, INCOMPLETE_SIGNATURE})


def client_ip(request: Request) -> str:
    """Best-effort client address for logging. Behind a reverse proxy this is
    already the real client (uvicorn --proxy-headers rewrites it); the header
    fallback is only for odd deployments."""
    if request.client and request.client.host:
        return request.client.host
    return request.headers.get("x-forwarded-for", "?").split(",")[0].strip() or "?"


def key_hint(key_id: Optional[str]) -> str:
    """A key-id is a public identifier, but log only enough to correlate."""
    if not key_id:
        return "-"
    return key_id[:8]


def auth_failure(
    request: Request,
    status: int,
    reason: str,
    message: str,
    *,
    key_id: Optional[str] = None,
    **extra: Any,
) -> HTTPException:
    """Log a failed auth attempt and build the HTTPException to raise.

    The response body is `{"detail": {"error": <reason>, "detail": <message>,
    "retryable": <bool>, ...}}` — `detail` stays human-readable so older
    clients (which surface it verbatim) keep showing something sensible.
    """
    log.warning(
        "auth failed: reason=%s status=%d ip=%s key=%s %s %s%s",
        reason,
        status,
        client_ip(request),
        key_hint(key_id),
        request.method,
        request.url.path,
        "".join(f" {k}={v}" for k, v in extra.items()),
    )
    payload: Dict[str, Any] = {
        "error": reason,
        "detail": message,
        "retryable": reason in RETRYABLE,
    }
    payload.update(extra)
    return HTTPException(status, payload)


def auth_ok(request: Request, *, key_id: Optional[str], auth_version: int) -> None:
    """Debug-level success trace. Off by default (INFO), but flipping the
    logger to DEBUG gives a full picture during an investigation."""
    if log.isEnabledFor(logging.DEBUG):
        log.debug(
            "auth ok: key=%s v%d ip=%s %s %s",
            key_hint(key_id),
            auth_version,
            client_ip(request),
            request.method,
            request.url.path,
        )


def event(message: str, *args: Any) -> None:
    """Notable auth-lifecycle event (enrolment, approval, revocation,
    upgrade). These are the things you want in the journal when a user says
    "it logged me out yesterday"."""
    log.info(message, *args)
