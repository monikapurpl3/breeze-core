"""
EnrollmentService — the device-pairing handshake (RFC 8628-style).

Flow:
  1. A client calls start() with the enrollment key → gets a session_id
     and a short user_code to display, valid for a few seconds.
  2. The admin, on the LAN, relays that user_code into the approval tool,
     which calls approve() → a per-device token is minted and stored
     (hashed) in the TokenStore, and stashed on the session for one-time
     pickup.
  3. The client polls poll(session_id) → once approved, it receives the
     token exactly once; the session is then consumed.

Pending sessions live in memory only: they're short-lived, and losing
them on a restart just means whoever was mid-enrollment starts over. The
minted tokens themselves are durable (TokenStore → devices.json).
"""
from __future__ import annotations

import secrets
import time
from dataclasses import dataclass, field
from typing import Dict, Optional, Tuple

from meow_ac.config.models import DeviceRecord
from meow_ac.security import crypto
from meow_ac.security.token_store import TokenStore

# Enrollment outcomes returned by poll().
PENDING = "pending"
APPROVED = "approved"
EXPIRED = "expired"
UNKNOWN = "unknown"


@dataclass
class _Session:
    code_hash: str
    label: str
    expires_at: float
    # Auth profile this client is enrolling for. v1 → a bearer token is
    # minted and handed out once. v2 → the client already generated an
    # Ed25519 keypair and gave us its public key; nothing secret is minted
    # or returned (the private key never leaves the device).
    auth_version: int = 1
    public_key: Optional[str] = None
    approved: bool = False
    # Populated on approval. `token` is the one-time bearer for v1 only.
    token: Optional[str] = None
    record: Optional[DeviceRecord] = field(default=None)


class EnrollmentService:
    def __init__(
        self,
        token_store: TokenStore,
        code_ttl_seconds: int = 60,
        token_ttl_days: int = 90,
    ):
        self._tokens = token_store
        self._code_ttl = code_ttl_seconds
        self._token_ttl_days = token_ttl_days
        self._sessions: Dict[str, _Session] = {}

    # -- step 1: a client requests enrollment -------------------------

    def start(
        self,
        label: str,
        auth_version: int = 1,
        public_key: Optional[str] = None,
    ) -> Tuple[str, str, int]:
        """Open a pending session. Returns (session_id, user_code,
        expires_in_seconds). The user_code is shown to the human; only
        its hash is retained.

        For auth_version 2 the client supplies its Ed25519 `public_key` here;
        it's validated by the caller (the API layer) before we get it.
        """
        self._sweep()
        session_id = secrets.token_urlsafe(18)
        user_code = crypto.new_pairing_code()
        self._sessions[session_id] = _Session(
            code_hash=crypto.hash_secret(crypto.normalize_code(user_code)),
            label=label.strip() or "unnamed device",
            expires_at=time.time() + self._code_ttl,
            auth_version=auth_version,
            public_key=public_key,
        )
        return session_id, user_code, self._code_ttl

    # -- step 2: the admin approves a code (LAN-only, enforced in API) -

    def approve(self, user_code: str) -> Optional[DeviceRecord]:
        """Approve a pending session by its user_code, minting a device
        token. Returns the new DeviceRecord, or None if no live pending
        session matches (wrong/expired/already-used code)."""
        self._sweep()
        target = crypto.hash_secret(crypto.normalize_code(user_code))
        matched: Optional[_Session] = None
        for session in self._sessions.values():
            # constant-time compare against each live session's code hash
            if crypto.constant_time_eq(session.code_hash, target) and not session.approved:
                matched = session
        if matched is None:
            return None

        now = time.time()
        expires_at = None if self._token_ttl_days <= 0 else now + self._token_ttl_days * 86400
        token: Optional[str] = None
        if matched.auth_version == 2:
            # v2: store only the client's public key. Nothing secret is
            # minted or handed back — the device signs with its private key.
            record = DeviceRecord(
                token_id=secrets.token_hex(8),
                label=matched.label,
                auth_version=2,
                public_key=matched.public_key,
                created_at=now,
                expires_at=expires_at,
            )
        else:
            # v1: mint a bearer token, store only its hash, hand it out once.
            token = crypto.new_device_token()
            record = DeviceRecord(
                token_id=secrets.token_hex(8),
                label=matched.label,
                auth_version=1,
                token_hash=crypto.hash_secret(token),
                created_at=now,
                expires_at=expires_at,
            )
        self._tokens.add(record)

        matched.approved = True
        matched.token = token
        matched.record = record
        return record

    # -- step 3: the client polls for its token -----------------------

    def poll(self, session_id: str) -> Tuple[str, Optional[str], Optional[DeviceRecord]]:
        """Check a session. Returns (status, token, record). The token is
        non-None only on the first APPROVED poll; the session is consumed
        at that point so a token is never handed out twice."""
        self._sweep()
        session = self._sessions.get(session_id)
        if session is None:
            return UNKNOWN, None, None
        if not session.approved:
            return PENDING, None, None
        # approved: deliver the token once, then consume the session
        token, record = session.token, session.record
        del self._sessions[session_id]
        return APPROVED, token, record

    # -- housekeeping --------------------------------------------------

    def _sweep(self) -> None:
        """Drop expired, un-approved sessions. Approved-but-not-yet-polled
        sessions are kept (the token is already minted and durable); they
        fall out on their next poll."""
        now = time.time()
        dead = [
            sid for sid, s in self._sessions.items()
            if not s.approved and s.expires_at < now
        ]
        for sid in dead:
            del self._sessions[sid]
