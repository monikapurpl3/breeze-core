"""
Application factory + the ASGI entry point.

`create_app()` is the single place where the pieces are assembled:
settings → config/token stores → device manager + authenticators →
routers → static UI. Everything is injected, so a test (or a future
variant of the service) can build an app with a different config path or
a different authenticator without any global state.

uvicorn serves the module-level `app` built from the environment:

    uvicorn meow_ac.app:app --host <lan-ip> --port 8420

Authentication (see meow_ac/security/ and the README):
- Full API access (units) requires the API key *and* a per-device token
  — `CompositeAuthenticator([api_key, device_token])`.
- The enrollment endpoints (/api/auth/*) need only the API key to begin;
  approval is admin-only and LAN-restricted.

Where to grow
-------------
- New API surface: write a `build_*` router factory and include it below.
- Middleware: add it here, guarded by a Settings flag.
"""
from __future__ import annotations

import logging
import mimetypes
from pathlib import Path
from contextlib import asynccontextmanager
from typing import Optional

from fastapi import FastAPI
from fastapi.staticfiles import StaticFiles
from starlette.middleware.trustedhost import TrustedHostMiddleware

from meow_ac.api import auth as auth_api
from meow_ac.api import config as config_api
from meow_ac.api import programs as programs_api
from meow_ac.api import units as units_api
from meow_ac.config.store import ConfigStore
from meow_ac.devices.manager import DeviceManager
from meow_ac.programs.scheduler import Scheduler
from meow_ac.programs.store import ProgramStore
from meow_ac.security.api_key import ApiKeyAuthenticator
from meow_ac.security.composite import CompositeAuthenticator
from meow_ac.security.device_token import DeviceTokenAuthenticator
from meow_ac.security.enrollment import EnrollmentService
from meow_ac.security.headers import SecurityHeadersMiddleware
from meow_ac.security.token_store import TokenStore
from meow_ac.settings import Settings

log = logging.getLogger("meow-ac")

# Static UI lives at the repo/deploy root, one level up from this package
# (…/meow_ac/app.py → …/static). Matches the deployed /opt/meow-ac/static.
STATIC_DIR = Path(__file__).resolve().parent.parent / "static"


def create_app(settings: Optional[Settings] = None) -> FastAPI:
    logging.basicConfig(level=logging.INFO)
    settings = settings or Settings.from_env()

    # Serve JS/CSS with correct MIME types even on hosts (notably the
    # Windows dev box) whose registry maps .js to text/plain — browsers
    # refuse to load ES modules that aren't a JavaScript MIME type.
    mimetypes.add_type("text/javascript", ".js")
    mimetypes.add_type("text/css", ".css")

    store = ConfigStore(settings.config_path)
    token_store = TokenStore(settings.devices_path)
    token_store.load()
    program_store = ProgramStore(settings.programs_path)
    program_store.load()
    manager = DeviceManager(store)
    enrollment = EnrollmentService(
        token_store,
        code_ttl_seconds=settings.code_ttl_seconds,
        token_ttl_days=settings.token_ttl_days,
    )
    scheduler = Scheduler(manager, program_store, settings.scheduler_tick_seconds)

    # Auth: the API key is the enrollment secret; full access also needs a
    # per-device token. Composing the two is a list — a further factor
    # would just be appended here (see security/base.py).
    api_key_auth = ApiKeyAuthenticator(store)
    device_auth = DeviceTokenAuthenticator(token_store)
    full_auth = CompositeAuthenticator([api_key_auth, device_auth])

    # Interactive docs are disabled by default so a public deployment
    # doesn't expose its schema; AC_DOCS=1 turns them on for dev.
    docs_kwargs = (
        {}
        if settings.docs_enabled
        else {"docs_url": None, "redoc_url": None, "openapi_url": None}
    )

    # Lifespan runs the background scheduler for the life of the process
    # (single worker → exactly one scheduler). Cancelled on shutdown.
    @asynccontextmanager
    async def lifespan(_app: FastAPI):
        await scheduler.start()
        try:
            yield
        finally:
            await scheduler.stop()

    app = FastAPI(title="meow-ac", lifespan=lifespan, **docs_kwargs)

    # Middleware is added inner-first; TrustedHost is added last so it runs
    # first and rejects spoofed Host headers before anything else.
    if settings.security_headers:
        app.add_middleware(SecurityHeadersMiddleware)
    if settings.trusted_hosts:
        app.add_middleware(TrustedHostMiddleware, allowed_hosts=settings.trusted_hosts)

    # No CORS middleware here on purpose. The control panel is served from
    # this same app, so its own requests are same-origin and need nothing
    # special. Adding permissive CORS would only let some *other* origin's
    # JavaScript call this API too. If the service is ever exposed to a
    # separate front-end origin, add CORS with an explicit, narrow origin
    # allowlist — never a wildcard.
    app.include_router(
        auth_api.build_auth_router(token_store, enrollment, settings, api_key_auth)
    )
    app.include_router(units_api.build_router(manager, full_auth))
    app.include_router(config_api.build_config_router(store, manager, full_auth))
    app.include_router(
        programs_api.build_programs_router(manager, program_store, scheduler, full_auth)
    )

    # Static mount is last so /api/* routes win over the catch-all.
    app.mount("/", StaticFiles(directory=STATIC_DIR, html=True), name="static")

    log.info(
        "meow-ac app created (config=%s, devices=%s, programs=%s, docs=%s, lan_only_enroll=%s)",
        settings.config_path, settings.devices_path, settings.programs_path,
        settings.docs_enabled, settings.enrollment_lan_only,
    )
    return app


app = create_app()
