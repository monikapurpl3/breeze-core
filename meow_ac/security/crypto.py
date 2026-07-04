"""
Small crypto helpers for the enrollment / device-token scheme.

Standard library only (secrets + hashlib) — device tokens are
high-entropy random strings, so a fast hash (SHA-256) is the correct
choice for storing them; a slow password hash (argon2/bcrypt) would buy
nothing here because there's no low-entropy secret to protect.
"""
from __future__ import annotations

import base64
import hashlib
import secrets

# Bytes of entropy for the opaque per-device access token. 32 bytes =
# 256 bits; token_urlsafe renders it as ~43 URL-safe characters.
_TOKEN_BYTES = 32

# Bytes behind the short human-typed pairing code. 5 bytes = 40 bits,
# rendered as 8 base32 chars — ample against guessing inside a 60s,
# rate-limited, single-use window.
_CODE_BYTES = 5


def new_device_token() -> str:
    """A fresh opaque access token to hand to a client."""
    return secrets.token_urlsafe(_TOKEN_BYTES)


def hash_secret(secret: str) -> str:
    """Hex SHA-256 of a secret, for at-rest storage. Never store the
    secret itself — only compare hashes."""
    return hashlib.sha256(secret.encode("utf-8")).hexdigest()


def constant_time_eq(a: str, b: str) -> bool:
    """Constant-time string comparison (both operands are hex digests
    or codes of fixed length here)."""
    return secrets.compare_digest(a, b)


def new_pairing_code() -> str:
    """A short, uppercase, human-typeable one-time code, e.g. 'K7Q2-9MRX'.

    Base32 (no padding, no lowercase); a hyphen splits it into two
    groups so it's easier to read aloud and type.
    """
    raw = base64.b32encode(secrets.token_bytes(_CODE_BYTES)).decode("ascii").rstrip("=")
    return f"{raw[:4]}-{raw[4:]}"


def normalize_code(code: str) -> str:
    """Canonicalize a user-entered code for comparison: uppercase, strip
    spaces/hyphens so 'k7q2 9mrx' and 'K7Q2-9MRX' match."""
    return "".join(code.split()).replace("-", "").upper()
