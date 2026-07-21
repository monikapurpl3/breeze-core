"""
TokenStore — persistence and lookup for enrolled per-device tokens.

Kept deliberately separate from ConfigStore: config.json is
admin-managed (units + the enrollment api_key), whereas devices.json is
written by the *running app* as clients enroll and get revoked. Keeping
them in different files means a token write can never clobber the unit
list, and the two writers (setup_device.py vs. the service) never race.

The file is loaded once at startup and held in memory. It's rewritten
only on add/revoke (rare); `touch()` updates last_used in memory only,
so the hot path — verifying a token on every request — does no disk I/O.
`last_used` is therefore best-effort across restarts, which is fine for
what it is (an activity hint, not a security control).
"""
from __future__ import annotations

import logging
import time
from pathlib import Path
from typing import List, Optional

from pydantic import ValidationError

from meow_ac.config.models import DeviceRecord, DevicesDoc
from meow_ac.security import crypto

log = logging.getLogger("meow-ac")


class TokenStore:
    def __init__(self, path: Path):
        self.path = Path(path)
        self._doc: Optional[DevicesDoc] = None

    # -- loading / saving ---------------------------------------------

    def load(self) -> DevicesDoc:
        """Load devices.json, tolerating a missing or corrupt file by
        starting empty (a broken token file must never wedge the
        service — worst case, clients re-enroll)."""
        if not self.path.exists():
            self._doc = DevicesDoc()
            return self._doc
        try:
            self._doc = DevicesDoc.model_validate_json(self.path.read_text())
        except (ValidationError, ValueError):
            log.warning("devices file %s unreadable — starting with no devices", self.path)
            self._doc = DevicesDoc()
        return self._doc

    @property
    def doc(self) -> DevicesDoc:
        if self._doc is None:
            self.load()
        assert self._doc is not None
        return self._doc

    def save(self) -> None:
        """Persist to disk, mode 600 (the file holds token hashes)."""
        try:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            self.path.write_text(self.doc.model_dump_json(indent=2))
            self.path.chmod(0o600)
        except PermissionError as e:
            # Almost always: the directory isn't owned/writable by the
            # service user (chowning only config.json, not its dir). Make
            # that obvious in the log rather than surfacing a bare 500.
            log.error(
                "cannot write %s (%s) — is its directory owned/writable by "
                "the service user? e.g. `chown -R meow-ac:meow-ac %s`",
                self.path, e, self.path.parent,
            )
            raise

    # -- mutation ------------------------------------------------------

    def add(self, record: DeviceRecord) -> None:
        # Persist first; only keep the record in memory if it made it to
        # disk. Otherwise a failed save() (e.g. an unwritable dir) would
        # leave an in-memory token that a later successful save silently
        # persists as an orphan credential.
        self.doc.devices.append(record)
        try:
            self.save()
        except Exception:
            self.doc.devices.pop()
            raise

    def revoke(self, token_id: str) -> bool:
        before = len(self.doc.devices)
        self.doc.devices = [d for d in self.doc.devices if d.token_id != token_id]
        removed = len(self.doc.devices) != before
        if removed:
            self.save()
        return removed

    # -- lookup --------------------------------------------------------

    def find_by_secret(self, secret: str) -> Optional[DeviceRecord]:
        """Return the (unexpired) v1 record whose token hash matches, or None.

        Compares against every v1 record with a constant-time check so a
        present-but-wrong token isn't distinguishable by timing from an
        absent one. v2 records (no token_hash) are skipped — a v2 device
        cannot authenticate with a bearer token (no silent downgrade).
        """
        candidate = crypto.hash_secret(secret)
        now = time.time()
        match: Optional[DeviceRecord] = None
        for record in self.doc.devices:
            if record.token_hash is None:
                continue
            if crypto.constant_time_eq(record.token_hash, candidate):
                match = record
        if match is None:
            return None
        if match.expires_at is not None and match.expires_at < now:
            return None
        return match

    def find_by_key_id(self, token_id: str) -> Optional[DeviceRecord]:
        """Return the (unexpired) v2 record named by `token_id`, or None.

        The token_id is a public identifier (sent in the clear as the
        X-Breeze-Key-Id header); it only *names* the device, and possession
        of the matching private key — proven by the request signature — is
        what authorizes. So a plain lookup is fine here.
        """
        now = time.time()
        for record in self.doc.devices:
            if record.token_id != token_id or record.auth_version != 2:
                continue
            if record.expires_at is not None and record.expires_at < now:
                return None
            return record
        return None

    def upgrade_to_v2(self, token_id: str, public_key: str) -> bool:
        """Migrate an existing v1 device to v2 in place: keep its identity
        (token_id/label/created_at/expiry) but replace the bearer credential
        with an Ed25519 public key. Returns False if no such device."""
        for record in self.doc.devices:
            if record.token_id == token_id:
                record.auth_version = 2
                record.public_key = public_key
                record.token_hash = None
                self.save()
                return True
        return False

    def touch(self, token_id: str) -> None:
        """Record last-use in memory (not persisted, to keep the verify
        path disk-free)."""
        for record in self.doc.devices:
            if record.token_id == token_id:
                record.last_used = time.time()
                return

    def list(self) -> List[DeviceRecord]:
        return list(self.doc.devices)
