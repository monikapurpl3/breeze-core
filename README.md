# Breeze Core

Self-hosted control for **Midea air conditioners** — a LAN-first REST API, a web control panel, and a diagnostic CLI, plus an optional native Android app (**Breeze**). After a one-time local pairing there is **no cloud dependency**: your units are controlled directly over your own network.

Built on [msmart-ng](https://github.com/mill1000/midea-msmart) (device I/O), [FastAPI](https://fastapi.tiangolo.com/) + [uvicorn](https://www.uvicorn.org/) (HTTP), vanilla-JS ES modules (web UI), and zsh (diagnostics). Runs on any mainstream Linux distribution — systemd is the smoothest path, but non-systemd inits (OpenRC, runit, s6, supervisord), musl-libc distros (Alpine, Void), the BSDs, macOS, and **Windows** (guided installer + service + Caddy) are supported too (see the install guide).

> **Naming.** The project/product is **Breeze Core**. Under the hood the Python package is `meow_ac`, so the uvicorn entry point you'll see in commands is `meow_ac.app:app`. Everything else (install directory, service name, config directory) is up to you — this guide uses `/opt/breeze-core`, `breeze-core.service`, and `/etc/breeze-core`, all wired via environment variables.

---

## Contents

- [What you get](#what-you-get)
- [Architecture](#architecture)
- [Requirements](#requirements)
- [Quickstart](#quickstart)
- [Detailed guides](#detailed-guides)
- [Configuration](#configuration)
- [Authentication (device pairing)](#authentication-device-pairing)
- [REST API reference](#rest-api-reference)
- [Control / state schema](#control--state-schema)
- [Web UI](#web-ui)
- [Diagnostic & approval tools](#diagnostic--approval-tools)
- [The Breeze app](#the-breeze-app)
- [Security](#security)
- [Sharing / license](#sharing--license)

---

## What you get

Four decoupled components that share exactly one contract — the `/api/*` endpoints:

| Component | Path | What it is |
|---|---|---|
| **Server** | `meow_ac/` | The FastAPI app — the only stateful part. A standalone REST API (`meow_ac.app:app`). |
| **Web UI** | `static/` | Self-contained vanilla-JS control panel, served by the app. Just an API client. |
| **Diagnostic CLI** | `tools/ac-diag.zsh` | HTTP-only health/latency checker. |
| **Approval CLI** | `tools/ac-approve.zsh` | Admin tool to approve device pairings and manage tokens (LAN-only). |
| **Breeze (Android)** | *separate repo* | Optional native app — mirrors the web UI plus programs, diagnostics, and server switching. See the [**breeze**](https://github.com/monikapurpl3/breeze) repository. |

Delete any client and the API and the others keep working.

---

## Architecture

```
   Browser / Breeze app ─┐
                         │  HTTPS (via reverse proxy)  or  HTTP on the LAN
   ac-diag.zsh ──────────┤
                         ▼
              ┌─────────────────────────────┐
              │  uvicorn → meow_ac.app:app   │   (systemd service, one worker)
              │   ├── /api/auth/*   pairing  │
              │   ├── /api/units*   control  │
              │   ├── /api/programs favourites/schedules/curves + scheduler
              │   └── /  static web UI       │
              │            │ msmart-ng       │
              │            ▼                 │
              │   AC device objects (cached) │
              └────────────┬────────────────┘
                           │ TCP :6444 per unit
                    Midea AC units on the LAN
```

Inside the package, work is split into small layers assembled by an app factory (`create_app()` in `meow_ac/app.py`): **settings** (env), **config** (`config.json` store), **security** (device-pairing auth), **devices** (connection lifecycle + wire schema), **programs** (favourites/schedules/curves + a background scheduler), and **api** (router factories). Connections are lazy and cached per unit; every read/write is a live LAN round-trip.

---

## Requirements

- A host with network access to your AC units (a small always-on machine: mini-PC, NUC, Raspberry Pi, old laptop, VM…). **systemd** Linux is the smoothest path and the only one with the built-in sandbox; **non-systemd inits** (OpenRC/runit/s6/supervisord), **musl-libc** distros (Alpine, Void), the **BSDs**, **macOS**, and **Windows** (guided installer + hardened service + Caddy — see [docs/WINDOWS.md](docs/WINDOWS.md)) are supported too.
- **Python 3.11+**.
- **Midea AC units** on the same LAN, already provisioned to your WiFi with the *NetHome Plus* app (Breeze Core does not do WiFi provisioning).
- `curl` + `jq` + `zsh` for the diagnostic/approval CLIs (optional).
- **Optional, for remote access:** a reverse proxy (nginx or Apache) and a TLS certificate — see [docs/REVERSE-PROXY.md](docs/REVERSE-PROXY.md).

---

## Quickstart

This is the shortest path on any distro; the [per-distro install guide](docs/INSTALL.md) covers the packages, service user, firewall, and distro-specific hardening properly.

```bash
# 1. get the code (example: /opt/breeze-core) and a virtualenv
sudo mkdir -p /opt/breeze-core && sudo chown "$USER" /opt/breeze-core
git clone <repo-url> /opt/breeze-core        # or copy the tree here
cd /opt/breeze-core
python3 -m venv venv
./venv/bin/pip install -r requirements.txt

# 2. discover + pair your units (writes config.json; prints an API key once)
sudo mkdir -p /etc/breeze-core
AC_CONFIG=/etc/breeze-core/config.json ./venv/bin/python setup_device.py

# 3. run it (bind your LAN IP; 8420 by default)
AC_CONFIG=/etc/breeze-core/config.json \
  ./venv/bin/uvicorn meow_ac.app:app --host 192.168.1.10 --port 8420
```

Open `http://192.168.1.10:8420` on the LAN, enter the API key, and pair. For a real deployment run it as a **systemd service** (survives reboots, sandboxed) — see the install guide.

---

## Detailed guides

- **[docs/INSTALL.md](docs/INSTALL.md)** — step-by-step install as a service, with separate instructions for **RHEL & compatibles**, **Debian & compatibles**, **openSUSE/SLES**, **NixOS/Nix**, and **other** distros, plus first-class paths for **non-systemd inits** (OpenRC, runit, s6, supervisord, SysV), **non-glibc / musl** systems (Alpine, Void-musl), and the **BSDs / macOS** — including the distro-specific extras that help (SELinux, AppArmor, firewalld/ufw/nftables, declarative NixOS).
- **[docs/WINDOWS.md](docs/WINDOWS.md)** — Windows as a first-class target: a guided **NSIS installer**, Breeze Core as a hardened Windows **service** (bundled NSSM, `LOCAL SERVICE`, LAN-locked firewall), an optional guided **Caddy** reverse proxy (automatic HTTPS), and a **fail2ban-style** IP banner. Scripts live in [`deploy/windows/`](deploy/windows/).
- **[docs/REVERSE-PROXY.md](docs/REVERSE-PROXY.md)** — exposing Breeze Core beyond the LAN: **nginx** and **Apache** configs (separately), **TLS certificates** (Let's Encrypt via certbot and via acme.sh), and the app-side settings that make it safe behind a proxy. For automation, [`deploy/reverse-proxy-wizard.sh`](deploy/reverse-proxy-wizard.sh) generates and installs it (with a `--dry-run`); on **Windows** the [Caddy wizard](docs/WINDOWS.md#5-expose-it-publicly-with-caddy) does the equivalent.
- **[docs/DOCKER.md](docs/DOCKER.md)** — run Breeze Core as a container: a compact, non-root image on Red Hat **UBI 9** (multi-arch, published to GHCR), with a Compose example.
- **[HARDENING.md](HARDENING.md)** — the security review + public-exposure runbook and go-live checklist.

---

## Configuration

`config.json` — written and maintained by `setup_device.py`, read and validated by the app. Its location is set by `AC_CONFIG` (this guide uses `/etc/breeze-core/config.json`).

```json
{
  "api_key": "randomly-generated-urlsafe-string",
  "units": [
    { "name": "Living Room", "ip": "192.168.1.73", "port": 6444,
      "id": 153931628470980, "token": null, "key": null }
  ]
}
```

| Field | Notes |
|---|---|
| `api_key` | The **enrollment** secret — needed to *begin* pairing (see [Authentication](#authentication-device-pairing)). Generated by `setup_device.py`. |
| `units[].name/ip/port/id` | Friendly name, LAN IP, control port (usually `6444`), Midea device id. |
| `units[].token/key` | V3 auth credentials (`null` for V1/V2). Back these up — they can't be re-derived if the Midea cloud is unreachable. |

### Runtime settings (environment variables)

Read once at startup. Defaults are safe for public exposure (docs off, headers on, LAN-only approval).

| Var | Default | Purpose |
|---|---|---|
| `AC_CONFIG` | `/etc/meow-ac/config.json` | config file path |
| `AC_DEVICES` | `<config dir>/devices.json` | per-device token store (app-written) |
| `AC_PROGRAMS` | `<config dir>/programs.json` | favourites/schedules/curves (app-written) |
| `AC_SCHED_TICK` | `30` | scheduler evaluation interval (seconds) |
| `AC_DOCS` | off | set `1` to expose `/docs` (dev only) |
| `AC_SECURITY_HEADERS` | on | emit CSP/HSTS/etc. (turn off if your proxy sets them) |
| `AC_TRUSTED_HOSTS` | any | CSV Host allow-list (`TrustedHostMiddleware`) |
| `AC_BEHIND_PROXY` | off | trust `X-Forwarded-For` for the real client IP |
| `AC_ENROLL_LAN_ONLY` | on | pairing approval must come from a private/LAN address |
| `AC_CODE_TTL` | `60` | pairing-code lifetime (seconds) |
| `AC_TOKEN_TTL_DAYS` | `90` | device-token lifetime; `0` = never expires |

> Point them at your chosen config dir, e.g. `AC_CONFIG=/etc/breeze-core/config.json` — `AC_DEVICES`/`AC_PROGRAMS` then default alongside it.

---

## Authentication (device pairing)

Breeze Core uses an **RFC 8628-style device-pairing** flow, so no long-lived shared password rides on every request:

- The **`api_key`** is an *enrollment* secret: on its own it only authorizes *starting* a pairing.
- A client `POST`s `/api/auth/enroll/start` (with the key) and shows a short, single-use **code** (~60 s).
- An **admin on the LAN** approves that code (via `tools/ac-approve.zsh` or `POST /api/auth/enroll/approve`).
- The client polls `/api/auth/enroll/poll` and receives a **per-device token** — 256-bit, stored **hashed**, individually named, revocable, and expiring.
- **Control endpoints require the API key *and* a valid device token.** Approval and device management are admin-only and restricted to the local network.

Rotating the `api_key` doesn't log devices out (tokens are independent); revoke a single lost device with `ac-approve.zsh revoke <token_id>`.

---

## REST API reference

Base URL: `http://<host>:8420` (or your HTTPS proxy URL). All comparisons are constant-time. Responses are compressed with **brotli** (gzip fallback) when the client sends `Accept-Encoding` — disable with `AC_COMPRESSION=0`.

### Pairing — `/api/auth`
```
POST /api/auth/enroll/start     X-API-Key       → {session_id, user_code, expires_in}
POST /api/auth/enroll/poll      X-API-Key       → {status[, device_token, token_id, label, expires_at]}
POST /api/auth/enroll/approve   X-API-Key + LAN → {token_id, label}                    (admin)
GET  /api/auth/devices          X-API-Key + LAN → [{token_id, label, created_at, ...}]  (admin)
DELETE /api/auth/devices/{id}   X-API-Key + LAN → 204                                   (admin)
```

### Meta — `/api` (health is public; version needs the API key)
```
GET   /api/health               → {status:"ok"}                 (public liveness probe)
GET   /api/version   X-API-Key  → {name, version, features[], units}   (feature-detect)
```

### Units — `/api/units` (require API key **+** device token)
```
GET    /api/units               → [{id, name, ip}]
GET    /api/units/state         → {states:[…], errors:[{id,name,ip,detail}]}  (all units,
                                   fanned out concurrently; unreachable units → online:false
                                   in states, or in errors — never 503s the whole batch)
GET    /api/units/{id}/state    → full state (connects + refreshes the unit)
POST   /api/units/{id}/control  → full state (applies only the fields present)
PATCH  /api/units/{id}          → rename a unit (body {name}) → sanitized unit view
POST   /api/units               → add a unit by LAN IP (body {ip, name?}); discovers
                                   it and writes config.json → 201 sanitized unit view
DELETE /api/units/{id}          → remove a unit from config → 204
GET    /api/config              → sanitized config: [{id,name,ip,port,has_v3_credentials}]
                                   (never returns the api_key or V3 token/key secrets)
```
State object:
```json
{ "id":"…","name":"…","ip":"…","online":true,"power_state":true,
  "operational_mode":"COOL","target_temperature":22.0,
  "indoor_temperature":26.3,"outdoor_temperature":31.0,
  "fan_speed":102,"swing_mode":"BOTH","eco":false,"turbo":false }
```
Errors: `401` bad key/token · `404` unknown unit · `422` out-of-range value · `503` unreachable/apply-failed.

### Programs — `/api/programs` (require API key + token; run server-side)
```
GET    /api/programs            → [Program]
POST   /api/programs            → 201 Program
GET/PUT/DELETE /api/programs/{id}
POST   /api/programs/{id}/apply → [UnitState]   (favourite→scene; curve→now; schedule→400)
GET    /api/programs/status     → {running, tick_seconds, runs, errors, last_run}
```
A **program** targets units (`unit_ids`, empty = all) and is one `kind`:
- **favourite** — a saved scene, applied on demand.
- **schedule** — `{days:[0–6, empty=daily], time:"HH:MM", settings}` triggers, fired when the clock crosses the minute.
- **curve** — `{operational_mode, fan_speed, points:[{time,temperature}]}`; the scheduler sets the interpolated setpoint (cyclic over the day, snapped to 0.5°). Times are **server-local**.

---

## Control / state schema

`operational_mode`: `AUTO COOL DRY HEAT FAN_ONLY` · `swing_mode`: `OFF VERTICAL HORIZONTAL BOTH` (two physical flaps; an unsupported one is silently ignored by firmware) · `target_temperature`: 16.0–30.0 in 0.5° steps · `fan_speed`: `20/40/60/80/100` + `102` (auto). `POST /control` always sets `beep = false`.

---

## Web UI

`static/`, served at `/`. Self-contained native ES modules — no build step, no external dependencies. Prompts for the API key on first load (stored in `localStorage`), runs the pairing flow, then shows a live control card per unit. Strict CSP; all styling is in `css/styles.css`, all logic in `js/` modules.

---

## Diagnostic & approval tools

Both are self-contained zsh scripts that speak only HTTP (they never import the package). They read `config.json` for the key.

```bash
# health/latency/enum checks on every unit
./tools/ac-diag.zsh --base-url http://<host>:8420 --config /etc/breeze-core/config.json --auto

# approve a pairing code / list / revoke (run on the LAN)
./tools/ac-approve.zsh --base-url http://<host>:8420 --config /etc/breeze-core/config.json approve <CODE>
./tools/ac-approve.zsh --base-url http://<host>:8420 --config /etc/breeze-core/config.json list
```

---

## The Breeze app

Optional native Android client — its own repository, **[breeze](https://github.com/monikapurpl3/breeze)**: the web UI's controls plus an in-app diagnostics screen, a favourites/schedule/temperature-curve editor, server switching, and Material You dynamic theming. Credentials are stored in Android Keystore-backed encrypted storage; it talks to the same API. Build with `flutter build apk --release` (see its README).

---

## Security

Breeze Core is **LAN-first**. Before exposing it to the internet, read **[HARDENING.md](HARDENING.md)** — it covers the threat model, the strongly-recommended VPN alternative, and, if you do go public, the full runbook (TLS, rate limiting, fail2ban, systemd egress lockdown, and a go-live checklist). What the app enforces on its own: two-credential access (key + per-device token), admin actions gated to the LAN, in-app rate limiting, strict security headers, docs disabled by default, and server-side input bounds.

---

## Sharing / license

Breeze Core is **free software licensed under the GNU Affero General Public License v3.0** ([AGPL-3.0](LICENSE)). It has no telemetry and no cloud callbacks after pairing. You may run, study, share, and modify it; if you run a **modified** version as a network service for others, AGPL §13 requires you to offer them your modified source. All dependencies are permissive (MIT / BSD-3 / Apache-2.0), which AGPL-3.0 allows.

The companion Android app, [**breeze**](https://github.com/monikapurpl3/breeze), is AGPL-3.0 as well.
