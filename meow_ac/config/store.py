"""
ConfigStore — the one place that reads and writes config.json.

Both the running service and setup_device.py go through this, so the
file format, permissions (mode 600), and merge-by-id semantics live in a
single spot instead of being duplicated across a loader in the app and a
writer in the setup script.

The service loads lazily and caches (matching the original
`_ensure_loaded` behavior): the first component to touch `.config`
triggers a read; nothing re-reads the file until `reload()` is called.
That `reload()` is the seam for "add a unit from the web UI" — mutate
via `add_or_update_unit()`, `save()`, then `reload()` so the running
DeviceManager sees the new unit.
"""
from __future__ import annotations

import json
import logging
import secrets
from pathlib import Path
from typing import Optional, Tuple

from pydantic import ValidationError

from meow_ac.config.models import AppConfig, UnitConfig

log = logging.getLogger("meow-ac")


class ConfigStore:
    def __init__(self, path: Path):
        self.path = Path(path)
        self._config: Optional[AppConfig] = None

    # -- reading -------------------------------------------------------

    def load(self) -> AppConfig:
        """Read and validate config.json, caching the result.

        Raises RuntimeError with actionable guidance if the file is
        missing — this is what the user sees on the first request after
        a fresh install with no config yet.
        """
        if not self.path.exists():
            raise RuntimeError(
                f"No config at {self.path}. Run setup_device.py first to "
                "discover and pair with your units."
            )
        self._config = AppConfig.model_validate(json.loads(self.path.read_text()))
        return self._config

    @property
    def config(self) -> AppConfig:
        """The cached config, loading it on first access."""
        if self._config is None:
            self.load()
        assert self._config is not None
        return self._config

    def reload(self) -> AppConfig:
        """Drop the cache and re-read from disk."""
        self._config = None
        return self.config

    def ensure_ready(self) -> AppConfig:
        """Load and assert the config is usable for serving requests.

        Requires an `api_key` (a config without one is unconfigured —
        surfaced with setup guidance rather than a confusing downstream
        error). An **empty unit list is allowed**: it's a legitimate
        runtime state now that units can be removed via
        `DELETE /api/units/{id}`, and the routes return empty results /
        404s for it rather than the whole API 500-ing on every call.
        """
        config = self.config
        if not config.api_key:
            raise RuntimeError(
                f"{self.path} has no api_key. Re-run setup_device.py to "
                "generate one (it preserves your existing units)."
            )
        return config

    def read_lenient(self) -> Tuple[AppConfig, str]:
        """Tolerant read for tooling (setup_device.py).

        Never raises for a missing or corrupt file — returns an empty
        config instead, plus a status of "ok" | "missing" | "invalid"
        so the caller can print an appropriate message. This is what
        lets `setup_device.py` merge into an existing config while still
        starting fresh if the file was hand-edited into invalid JSON.
        """
        if not self.path.exists():
            self._config = AppConfig()
            return self._config, "missing"
        try:
            data = json.loads(self.path.read_text())
            self._config = AppConfig.model_validate(data)
            return self._config, "ok"
        except (json.JSONDecodeError, ValidationError):
            self._config = AppConfig()
            return self._config, "invalid"

    # -- mutation (used by setup, and by any future add-from-UI path) --

    def ensure_api_key(self) -> str:
        """Return the api_key, generating and caching one if absent.

        Does not persist on its own — call `save()` afterward.
        """
        config = self.config
        if not config.api_key:
            config.api_key = secrets.token_urlsafe(24)
        return config.api_key

    def add_or_update_unit(self, unit: UnitConfig) -> None:
        """Merge a unit into the config by device id.

        Existing units with the same id are replaced (preserving order);
        new ones are appended. Callers that want to keep a previously
        set friendly name should read it off the existing entry first
        (see `find_unit`) before building the replacement.
        """
        config = self.config
        for i, existing in enumerate(config.units):
            if existing.id == unit.id:
                config.units[i] = unit
                return
        config.units.append(unit)

    def find_unit(self, unit_id: str) -> Optional[UnitConfig]:
        """Look up a unit by its string id, or None."""
        for unit in self.config.units:
            if unit.unit_id == unit_id:
                return unit
        return None

    def remove_unit(self, unit_id: str) -> bool:
        """Drop a unit from the config by id. Returns True if one was
        removed. Does not persist on its own — call `save()` afterward."""
        config = self.config
        before = len(config.units)
        config.units = [u for u in config.units if u.unit_id != unit_id]
        return len(config.units) != before

    # -- writing -------------------------------------------------------

    def save(self) -> None:
        """Persist the current config to disk, mode 640 (owner rw, group r).

        The file holds the API key and any V3 device tokens in plaintext, so it
        must never be **world**-readable. It is deliberately **group**-readable:
        the diagnostic/approval CLIs (`tools/ac-*.zsh`) read it directly for the
        key + base URL, so an admin added to the service's group can run them
        without sudo — which is exactly what those tools tell you to do. The
        containing directory stays 0750 (see INSTALL.md), so "group" means only
        the trusted service account + admins you add, never other local users.
        """
        config = self.config
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.path.write_text(config.model_dump_json(indent=2))
        self.path.chmod(0o640)
        log.info("Wrote %d unit(s) to %s", len(config.units), self.path)
