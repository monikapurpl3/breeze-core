# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A LAN-first REST API + web control panel + diagnostic CLI for controlling multiple Midea air conditioners, plus an optional native Android app (`breeze/`). No Home Assistant, no cloud dependency after initial pairing. Built on [msmart-ng](https://github.com/mill1000/midea-msmart) for device I/O, FastAPI/uvicorn for HTTP, vanilla JS for the UI, zsh for diagnostics.

**Branding vs. identifiers.** The project is publicly branded **Breeze Core** (that's the name in the shareable docs: `README.md`, `docs/INSTALL.md`, `docs/WINDOWS.md`, `docs/REVERSE-PROXY.md`, `HARDENING.md`). The *code* identifiers are unchanged and are the real technical names: Python package `meow_ac`, ASGI target `meow_ac.app:app`, systemd unit example `meow-ac.service`, env vars `AC_*`, default config dir `/etc/meow-ac` (the docs use `/etc/breeze-core` via `AC_CONFIG` since it's env-configurable). Don't rename the package/paths without a deliberate migration — the maintainer's live deployment uses the `meow-ac` names. Public docs are distro-generic (RHEL/Debian/SUSE/NixOS/other, plus non-systemd inits, musl, BSD/macOS, and **Windows**) and cover nginx + Apache + certbot/acme.sh (and **Caddy** on Windows); keep them generic, not tied to any one host. **Windows** ships a first-class path in `docs/WINDOWS.md` + `deploy/windows/` (NSIS installer, NSSM service, Caddy wizard, tripwire watcher) — the PowerShell/`.nsi`/`.cmd` files must stay **ASCII/BOM-free** so Windows PowerShell 5.1 (ANSI default) parses them.

## Architecture

Three components share one contract — the three `/api/*` endpoints — and are otherwise fully decoupled. Deleting either client leaves the API and the other client working.

- **`meow_ac/`** — the FastAPI app, a layered Python package. The *only* stateful component; a standalone REST API that neither knows nor cares that a UI exists.
- **web UI** (`static/`) — self-contained vanilla JS ES modules, served as static files. Just an HTTP client of the API.
- **`tools/ac-diag.zsh`** — diagnostic CLI. Also just an HTTP client; reads `config.json` directly for the key/unit list but never imports the package.

**Package layout — assembled by an app factory.** `create_app()` in `meow_ac/app.py` is the one place everything is wired: it builds a `ConfigStore`, hands it to the `DeviceManager` and the authenticator, builds the router from those, mounts `static/`. Nothing reaches for global state; dependencies are injected. The module-level `app = create_app()` is what uvicorn serves (`meow_ac.app:app`).

| Layer | Module | Responsibility |
|---|---|---|
| Settings | `settings.py` | Env-driven runtime config, read once (`Settings.from_env`). Feature flags for public exposure (docs, headers, trusted hosts, behind-proxy, LAN-only enroll, token TTL). |
| Config | `config/` | `config.json` as a typed store — `ConfigStore` (`store.py`) + pydantic models (`models.py`). Admin-managed. Shared by the app and `setup_device.py`. |
| Security | `security/` | Device-pairing auth. `Authenticator` protocol (`base.py`); `ApiKeyAuthenticator` + `DeviceTokenAuthenticator` composed by `CompositeAuthenticator`; `EnrollmentService` (pairing handshake); `TokenStore` (hashed tokens → `devices.json`); `crypto`/`ratelimit`/`net`/`headers` helpers. |
| Devices | `devices/` | `DeviceManager` lifecycle/cache (`manager.py`), LAN discovery (`discovery.py`), wire schema `serialize`/`ControlRequest` w/ bounds (`schemas.py`), the shared `apply_to_unit` helper (`control.py`). |
| Programs | `programs/` | Favourites/schedules/curves: models (`models.py`), `ProgramStore` → `programs.json` (`store.py`), and the background `Scheduler` (`scheduler.py`) that fires them. |
| API | `api/` | Router factories: `build_router(manager, auth)` in `units.py`, `build_auth_router(...)` in `auth.py`, `build_programs_router(...)` in `programs.py`. |

**Scheduling (server-side).** Programs live in `programs.json` (a third store alongside `config.json`/`devices.json`). The `Scheduler` is one asyncio task started by the app's lifespan (single uvicorn worker → exactly one scheduler); each tick (`AC_SCHED_TICK`, default 30s) it fires `schedule` triggers on the matching minute and drives `curve` setpoints (interpolated, cyclic over 24h, re-applied only when the rounded 0.5° value changes). Both go through `devices/control.py:apply_to_unit` — the *same* path as the HTTP control route. Times are server-local. Endpoints under `/api/programs` require full auth (key + token). The `apply_to_unit` extraction means the control route is now a one-liner; keep both callers sharing it.

**Authentication (device-pairing, RFC 8628-style).** The `api_key` is an *enrollment* secret only. A client `POST`s `/api/auth/enroll/start` (key) → gets a single-use ~60s code → an **admin on the LAN** approves it (`/api/auth/enroll/approve` or `tools/ac-approve.zsh`) → client polls `/api/auth/enroll/poll` and receives a per-device token (256-bit, stored SHA-256-hashed in `devices.json`, revocable, expiring). Control routes (`/api/units*`) require **both** the API key and the token — `CompositeAuthenticator([ApiKeyAuthenticator, DeviceTokenAuthenticator])`. `/api/auth/*` approval + device management are admin-only and LAN-restricted. Adding a further factor = another `Authenticator` appended to the composite list in `create_app()`. See README "Authentication" and `HARDENING.md`.

**Device connection lifecycle (`DeviceManager`):** connections are lazy and cached per unit id in instance dicts (`_devices`, `_locks`). The first request for a unit after a (re)start pays connect + authenticate (V3) + `get_capabilities` + `refresh`; subsequent requests reuse the object. Every state read (`refresh()`) and control write (`apply()`) is still a live LAN round-trip — no push/subscribe, so per-call latency is inherent. Each unit has its own `asyncio.Lock` (`lock_for`) so concurrent requests to the same unit serialize. The manager holds the `ConfigStore` (not a snapshot), so a future `store.reload()` surfaces new units; `forget(unit_id)` drops a stale cached connection.

**Config is the source of truth, via `ConfigStore`.** All reads/writes of `config.json` go through it — the app loads lazily and caches (`config` property / `ensure_ready()`), `setup_device.py` uses `read_lenient()` + `add_or_update_unit()` + `save()` (which chmods 600). `$AC_CONFIG` overrides the path (default `/etc/meow-ac/config.json`). The file holds the shared `api_key` and the unit list (with V3 `token`/`key` per unit).

## Commands

There is no build step, test suite, or linter. This is a small deploy-by-scp project.

```bash
# Run the server locally, from the repo root (so meow_ac imports and static/ is found)
AC_CONFIG=./config.json AC_DOCS=1 uvicorn meow_ac.app:app --host 127.0.0.1 --port 8420
# AC_DOCS=1 re-enables /docs for dev (off by default). 127.0.0.1 counts as
# "the LAN" so you can approve your own pairing locally. Production binds a
# specific LAN IP (or 127.0.0.1 behind nginx), never 0.0.0.0.

# Approve a device pairing / list / revoke (admin, from the LAN)
./tools/ac-approve.zsh --base-url http://127.0.0.1:8420 --config ./config.json approve <CODE>

# Discover + pair devices, write config.json (requires real Midea units on the LAN)
# Run from the repo root — setup_device.py imports the meow_ac package.
python setup_device.py                    # broadcast, finds all units
python setup_device.py --ip 192.168.1.50  # add/update one unit by IP
python setup_device.py --no-prompt --out ./config.json

# Run the diagnostic CLI against a running server (needs curl + jq; zsh)
./tools/ac-diag.zsh --base-url http://192.168.1.10:8420 --config ./config.json --auto

# Syntax-check the package without installing deps (msmart-ng not needed to compile)
python -m py_compile setup_device.py meow_ac/*.py meow_ac/**/*.py
```

The diagnostic tool's `--auto` mode doubles as the closest thing to a test suite: it verifies connectivity, auth (rejects no-key/wrong-key, accepts correct), unit-count parity between API and config, per-unit state validity, and enum value sanity. There is no way to run any of this without live hardware or a mock server standing in for the API.

## Conventions and gotchas specific to this repo

- **Add new work through the seams, not by widening a module.** New endpoint → write a `build_*` router factory (mirror `api/units.py`), take collaborators as args, `include_router` it in `create_app()`. New auth factor → implement the `Authenticator` protocol (`security/base.py`) and pass it to `create_app()`; endpoints depend on "the authenticator" and don't change. Add-from-UI → discovery (`devices/discovery.py`) and config writing (`ConfigStore.add_or_update_unit`/`save`) are already decoupled and shared with `setup_device.py`. See the "Extending meow-ac" section of README.md.
- **The app is a package; `WorkingDirectory`/cwd matters.** uvicorn target is `meow_ac.app:app` and must run with the repo/`/opt/meow-ac` root as cwd so the package imports and `STATIC_DIR` (`meow_ac/../static`) resolves. `setup_device.py` likewise imports `meow_ac`, so run it from the root. A flattened `scp` (contents dumped at top level) breaks both the import and the static mount — check `static/`, `tools/`, `meow_ac/` are subdirs after copying.
- **Never add CORS middleware.** Its absence is intentional and load-bearing (documented inline in `create_app`): the UI is same-origin, and permissive CORS would let any other LAN page drive the API. If the service is ever exposed outward, do it via a reverse proxy with a narrow origin allowlist, not wildcard CORS.
- **Read enum members with `.name`, never `str()`.** `serialize()` (`devices/schemas.py`) uses `device.operational_mode.name` / `swing_mode.name`. A prior bug used `str(...).split(".")[-1]`, which silently returned bare integers on Python 3.11+ (`IntEnum.__str__` changed). Keep using `.name`.
- **The UI auth wrapper is isolated in `static/js/api.js` — keep every request going through it.** `apiFetch()` injects `X-API-Key` from `localStorage` (`meow_ac_key`); on 401 it clears the key and re-prompts. A past wholesale UI rewrite dropped this and shipped a UI that 401'd on every call. Never call `fetch()` directly from other modules — route through `apiFetch`.
- **The UI is native ES modules, no bundler.** `index.html` loads `js/app.js` via `<script type="module">`; modules import each other with relative paths. `create_app()` registers `.js`/`.css` MIME types at startup so this works even on the Windows dev box (whose registry serves `.js` as `text/plain`, which browsers refuse for modules). Don't introduce a build step.
- **zsh `$path` is `$PATH`.** In `tools/ac-diag.zsh`, never name a local variable `path` (also `fpath`, `cdpath`) — zsh ties it to the command search path and everything breaks with "command not found". The HTTP helper uses `endpoint` for this reason. The script also avoids `bc` and `int()` math-func dependencies on purpose (native zsh arithmetic and `${ms%.*}` truncation). It's a single self-contained file (copied to `~/.local/bin/acdiag`) and must not import the package — keep it HTTP-only.
- **Constant-time secret checks.** API key, code hashes, and token hashes all compare via `secrets.compare_digest` (`security/crypto.py`, `api_key.py`). Keep it. Store only hashes of tokens/codes — never the plaintext.
- **Authenticators read from `Request`, not `Header(...)` params** — that's what lets `CompositeAuthenticator` call them in sequence. Keep new authenticators to the `async def __call__(self, request)` shape.
- **`devices.json` is a separate, app-written store (`TokenStore`), not part of `ConfigStore`.** This avoids racing `setup_device.py`'s writes to `config.json` and keeps admin config separate from runtime tokens. The verify path does no disk I/O (`touch()` updates `last_used` in memory only).
- **LAN-only approval needs the real client IP.** `enrollment_lan_only` (default on) checks the client is on a private network. Behind a reverse proxy set `AC_BEHIND_PROXY=1` (and run uvicorn `--proxy-headers --forwarded-allow-ips`) or every request looks like `127.0.0.1`. See `security/net.py` and `HARDENING.md`.
- **Interactive docs are off by default** (`docs_url=None` unless `AC_DOCS=1`) so a public deployment doesn't leak its schema. Don't unconditionally re-enable them.
- **Strict CSP — no inline styles/scripts in the UI.** `SecurityHeadersMiddleware` sets `default-src 'self'`. Keep CSS in `styles.css` and JS in modules; apply dynamic styling via `element.style` in JS (allowed), never `style="..."` attributes or `<style>`/inline handlers (blocked). Adding either forces loosening the CSP.
- **Keep `HARDENING.md` in sync** when you touch auth, settings, middleware, or the systemd unit — it's the public-exposure runbook and the go-live checklist references specific env vars/directives.
- **Preserve the wire contract.** The `serialize()` dict shape and `ControlRequest` fields are depended on by all three components; the endpoint error codes/messages (`400` bad enum, `401`, `404` unknown unit, `503` unreachable/apply-failed) and `ConfigStore.ensure_ready()` setup-guidance messages were kept identical through the modular refactor. Change deliberately.

## Control/state schema (used by all three components)

`operational_mode`: `AUTO COOL DRY HEAT FAN_ONLY` · `swing_mode`: `OFF VERTICAL HORIZONTAL BOTH` (maps to two physical flaps; sending an unsupported one is silently ignored by firmware) · `target_temperature`: 16.0–30.0 in 0.5° steps · `fan_speed`: 20/40/60/80/100 + 102 (auto). `POST /control` applies only the fields present and always sets `device.beep = False`. See README.md for the full REST reference, the deployment runbook, and the extension-point guide.
