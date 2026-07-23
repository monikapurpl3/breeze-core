"""
Request signing for auth-version 2 (Ed25519 + SHA3-512).

The v2 credential is an Ed25519 keypair generated on the client. Only the
**public key** ever reaches the server (stored in the DeviceRecord), so —
unlike the v1 bearer token, whose hash we store — a leak of devices.json
yields nothing an attacker can use to forge a request. The private key never
leaves the device.

Each request is signed over a canonical string binding the method, path,
timestamp, a per-request nonce, and a **SHA3-512 digest of the body**:

    breeze-auth-v2\n
    {METHOD}\n
    {path-with-query}\n
    {timestamp}\n
    {nonce}\n
    {sha3_512(body) hex}

Ed25519 (PureEdDSA, RFC 8032) signs those bytes directly. The timestamp
(bounded skew) + nonce (single-use within the skew window) give replay
protection; the body digest gives tamper protection. This is the exact
construction the Breeze app reproduces — keep the two in lockstep.

pycryptodome supplies both primitives and is already a dependency (msmart-ng
pulls it for Midea V3 AES), so v2 adds no new package.
"""
from __future__ import annotations

import base64
import binascii
import hashlib
import time
from typing import Dict

from Crypto.Hash import SHA3_512
from Crypto.PublicKey import ECC
from Crypto.Signature import eddsa

# Domain-separation prefix so a v2 signature can never be confused with any
# other signed blob the project might introduce later.
CANONICAL_PREFIX = "breeze-auth-v2"

# Public keys are Ed25519 → 32 raw bytes, carried as URL-safe base64 on the
# wire (the simplest thing for the app to produce). pycryptodome's
# ECC.import_key won't take a bare 32-byte key, so we wrap it in its fixed
# Ed25519 SubjectPublicKeyInfo DER prefix before importing — a stable,
# version-independent construction (the prefix never varies for Ed25519).
_PUBKEY_BYTES = 32
_ED25519_SPKI_PREFIX = binascii.unhexlify("302a300506032b6570032100")


def _import_public_key(raw: bytes):
    """Import a raw 32-byte Ed25519 public key as an EccKey (via SPKI wrap)."""
    return ECC.import_key(_ED25519_SPKI_PREFIX + raw)

# How far a request timestamp may drift from server time (seconds), each way.
# Also the lifetime a nonce is remembered for replay rejection.
DEFAULT_SKEW_SECONDS = 60


def sha3_512_hex(data: bytes) -> str:
    """Hex SHA3-512 of arbitrary bytes (the request-body digest)."""
    return hashlib.sha3_512(data).hexdigest()


def _b64d(value: str) -> bytes:
    """Decode URL-safe base64 that may have lost its padding on the wire."""
    pad = "=" * (-len(value) % 4)
    return base64.urlsafe_b64decode(value + pad)


def public_key_is_valid(public_key_b64: str) -> bool:
    """True if the string decodes to a well-formed Ed25519 public key.
    Called once at enrollment so a malformed key is rejected up front rather
    than on every later verify."""
    try:
        raw = _b64d(public_key_b64)
    except (ValueError, TypeError):
        return False
    if len(raw) != _PUBKEY_BYTES:
        return False
    try:
        _import_public_key(raw)
    except (ValueError, TypeError):
        return False
    return True


def build_canonical(method: str, path: str, timestamp: str, nonce: str, body: bytes) -> bytes:
    """Assemble the exact bytes that get signed/verified. `path` must be the
    request path including the query string (if any)."""
    return "\n".join(
        [CANONICAL_PREFIX, method.upper(), path, timestamp, nonce, sha3_512_hex(body)]
    ).encode("utf-8")


def verify_signature(public_key_b64: str, canonical: bytes, signature_b64: str) -> bool:
    """Verify an Ed25519 signature over `canonical`. Never raises — any
    decode/format/verify failure is a rejection (returns False)."""
    try:
        pub = _import_public_key(_b64d(public_key_b64))
        verifier = eddsa.new(pub, "rfc8032")
        verifier.verify(canonical, _b64d(signature_b64))
        return True
    except (ValueError, TypeError):
        return False


class NonceCache:
    """In-memory single-use nonce tracker for replay rejection.

    A nonce is accepted once and remembered for `skew_seconds`; a repeat
    inside that window is rejected. In-memory only (single uvicorn worker),
    mirroring the enrollment sessions: a restart forgets nonces, but replay
    still requires capturing a signed request over TLS and resending it
    within the skew window — a negligible edge that isn't worth persisting.
    """

    def __init__(self, skew_seconds: int = DEFAULT_SKEW_SECONDS):
        self._skew = skew_seconds
        self._seen: Dict[str, float] = {}

    def check_and_store(self, nonce: str, now: float) -> bool:
        """Return True if `nonce` is fresh (and record it); False if replayed."""
        self._sweep(now)
        if nonce in self._seen:
            return False
        self._seen[nonce] = now + self._skew
        return True

    def timestamp_in_window(self, timestamp: str, now: float) -> bool:
        """True if the client timestamp is within ±skew of server time."""
        try:
            ts = float(timestamp)
        except (TypeError, ValueError):
            return False
        return abs(now - ts) <= self._skew

    def _sweep(self, now: float) -> None:
        expired = [n for n, exp in self._seen.items() if exp < now]
        for n in expired:
            del self._seen[n]


def now_seconds() -> float:
    return time.time()
