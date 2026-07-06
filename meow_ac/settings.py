"""
Runtime settings for the meow-ac service.

Everything here is read from the environment exactly once, at app
construction, and passed explicitly into the components that need it —
nothing reaches back into the environment or into module globals. That
keeps the app testable (`create_app(Settings(...))`) and gives one
obvious place to grow.

The defaults are chosen to be safe for public exposure (docs off,
security headers on, enrollment approval restricted to the LAN). A dev
box loosens them via env vars (e.g. `AC_DOCS=1`). The bind address and
port stay with uvicorn/systemd (see meow-ac.service).
"""
from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path
from typing import List, Optional

DEFAULT_CONFIG_PATH = Path("/etc/meow-ac/config.json")


def _env_bool(name: str, default: bool) -> bool:
    raw = os.environ.get(name)
    if raw is None:
        return default
    return raw.strip().lower() in ("1", "true", "yes", "on")


def _env_int(name: str, default: int) -> int:
    raw = os.environ.get(name)
    try:
        return int(raw) if raw is not None else default
    except ValueError:
        return default


@dataclass(frozen=True)
class Settings:
    """Immutable snapshot of the service's runtime configuration."""

    config_path: Path
    devices_path: Path
    programs_path: Path

    # How often the background scheduler evaluates programs (seconds).
    scheduler_tick_seconds: int = 30

    # Interactive API docs (/docs, /redoc, /openapi.json). Off by default
    # so a public deployment doesn't leak its schema; AC_DOCS=1 in dev.
    docs_enabled: bool = False

    # Emit security response headers (HSTS, CSP, nosniff, ...). On by
    # default; turn off (AC_SECURITY_HEADERS=0) if your reverse proxy
    # sets them instead, to avoid duplicates.
    security_headers: bool = True

    # Compress responses (brotli when the client supports it, gzip
    # otherwise). Safe here — responses never contain secrets (the config
    # view is sanitized; tokens are never returned), so BREACH doesn't
    # apply. AC_COMPRESSION=0 to disable (e.g. if the proxy compresses).
    compression: bool = True

    # Host allowlist for TrustedHostMiddleware. None = allow any (dev);
    # set AC_TRUSTED_HOSTS="breeze.example.com,127.0.0.1" in production.
    trusted_hosts: Optional[List[str]] = None

    # Whether a reverse proxy sits in front. When true, the real client
    # IP is read from X-Forwarded-For (needed for the LAN-only approval
    # check). Only enable if a proxy you control sets that header.
    behind_proxy: bool = False

    # Enrollment approval must come from the local network (the admin
    # approves on the LAN). Strongly recommended for public deployments.
    enrollment_lan_only: bool = True

    # Lifetime of the short pairing code shown during enrollment.
    code_ttl_seconds: int = 60

    # Lifetime of a minted device token; 0 = never expires.
    token_ttl_days: int = 90

    @classmethod
    def from_env(cls) -> "Settings":
        config_path = Path(os.environ.get("AC_CONFIG", str(DEFAULT_CONFIG_PATH)))
        devices_env = os.environ.get("AC_DEVICES")
        devices_path = Path(devices_env) if devices_env else config_path.parent / "devices.json"
        programs_env = os.environ.get("AC_PROGRAMS")
        programs_path = Path(programs_env) if programs_env else config_path.parent / "programs.json"

        hosts_env = os.environ.get("AC_TRUSTED_HOSTS")
        trusted_hosts = (
            [h.strip() for h in hosts_env.split(",") if h.strip()] if hosts_env else None
        )

        return cls(
            config_path=config_path,
            devices_path=devices_path,
            programs_path=programs_path,
            scheduler_tick_seconds=_env_int("AC_SCHED_TICK", 30),
            docs_enabled=_env_bool("AC_DOCS", False),
            security_headers=_env_bool("AC_SECURITY_HEADERS", True),
            compression=_env_bool("AC_COMPRESSION", True),
            trusted_hosts=trusted_hosts,
            behind_proxy=_env_bool("AC_BEHIND_PROXY", False),
            enrollment_lan_only=_env_bool("AC_ENROLL_LAN_ONLY", True),
            code_ttl_seconds=_env_int("AC_CODE_TTL", 60),
            token_ttl_days=_env_int("AC_TOKEN_TTL_DAYS", 90),
        )
