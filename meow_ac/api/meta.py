"""
Liveness + version metadata.

- `GET /api/health` is **unauthenticated** — a minimal `{"status":"ok"}`
  liveness probe for the reverse proxy, Docker HEALTHCHECK, and uptime
  monitors. It deliberately leaks nothing (no version, no unit count) so
  it's safe to expose publicly.
- `GET /api/version` requires the **API key** (clients that talk to the
  service already have it) and returns the version plus a feature list a
  client can use to feature-detect — e.g. only offer "add unit by IP" if
  `"config_api"` is present, or the batch fetch if `"batch_state"` is.

Version is behind the key on purpose: broadcasting the exact build to
anonymous callers is the same schema-leak concern that keeps /docs off.
"""
from __future__ import annotations

import functools
import os
import subprocess
from pathlib import Path

from fastapi import APIRouter, Depends

from meow_ac import __version__
from meow_ac.devices.manager import DeviceManager
from meow_ac.security.base import Authenticator


@functools.lru_cache(maxsize=1)
def _commit() -> str:
    """Short git commit of this build, resolved once.

    Order: `AC_COMMIT` env (set by the container / systemd) → a
    `meow_ac/_commit.txt` dropped in at package/deploy time → `git` in a dev
    checkout → "unknown". Robust to the common case where the deployed tree
    isn't a git checkout.
    """
    env = os.environ.get("AC_COMMIT")
    if env:
        return env.strip()[:12]
    pkg = Path(__file__).resolve().parent.parent  # the meow_ac/ package dir
    try:
        f = pkg / "_commit.txt"
        if f.is_file():
            text = f.read_text().strip()
            if text:
                return text[:12]
    except OSError:
        pass
    try:
        out = subprocess.run(
            ["git", "rev-parse", "--short", "HEAD"],
            cwd=str(pkg.parent), capture_output=True, text=True, timeout=2,
        )
        if out.returncode == 0 and out.stdout.strip():
            return out.stdout.strip()
    except (OSError, subprocess.SubprocessError):
        pass
    return "unknown"

# Capabilities a client can rely on when talking to this build. Bump the
# list as endpoints are added so older/newer clients can feature-detect.
FEATURES = [
    "device_pairing",   # RFC 8628-style enrollment + per-device tokens
    "programs",         # favourites / schedules / curves
    "config_api",       # GET /api/config, PATCH/POST/DELETE /api/units
    "batch_state",      # GET /api/units/state
    "delete_unit",      # DELETE /api/units/{id}
    "compression",      # brotli/gzip response compression
]


def build_meta_router(api_key_auth: Authenticator, manager: DeviceManager) -> APIRouter:
    router = APIRouter(prefix="/api")

    @router.get("/health")
    async def health():
        return {"status": "ok"}

    @router.get("/version", dependencies=[Depends(api_key_auth)])
    async def version():
        return {
            "name": "Breeze Core",
            "version": __version__,
            "commit": _commit(),
            "features": FEATURES,
            "units": len(manager.known_units()),
        }

    return router
