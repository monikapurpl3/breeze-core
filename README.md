# Breeze Core

Self-hosted control for **Midea air conditioners** — a LAN-first REST API, a
web control panel, and a diagnostic CLI, plus an optional native Android app
(**Breeze**). After a one-time local pairing there is **no cloud dependency**:
your units are controlled directly over your own network.

![Breeze Core web UI — dashboard](docs/img/web-ui.png)

<sub>The web control panel — a live card per unit, six switchable colour
palettes, °C/°F, unit management, and a version footer. (Sample data.)</sub>

---

## What you get

Four decoupled components that share exactly one contract — the `/api/*` endpoints:

| Component | Path | What it is |
|---|---|---|
| **Server** | `meow_ac/` | The FastAPI app — the only stateful part. A standalone REST API. |
| **Web UI** | `static/` | Self-contained vanilla-JS control panel, served by the app. Just an API client. |
| **Diagnostic CLI** | `tools/ac-diag.zsh` | HTTP-only health/latency/security checker. |
| **Approval CLI** | `tools/ac-approve.zsh` | Admin tool to approve device pairings and manage tokens (LAN-only). |
| **Breeze (Android)** | [separate repo](https://github.com/monikapurpl3/breeze) | Optional native app — the web UI's controls plus programs, diagnostics, server switching, home-screen widgets. |

Delete any client and the API and the others keep working. Built on
[msmart-ng](https://github.com/mill1000/midea-msmart), [FastAPI](https://fastapi.tiangolo.com/) +
[uvicorn](https://www.uvicorn.org/), and plain ES modules — no build step anywhere.

> **Naming.** The product is **Breeze Core**; the Python package underneath is
> `meow_ac` (so the ASGI entry point is `meow_ac.app:app`). Install paths and
> service names are your choice — the docs use `/etc/breeze-core` etc., wired
> via environment variables.

---

## Get started

**Before you start:** your Midea units should already be on your Wi-Fi (done
once with the *NetHome Plus* phone app), and you need any small always-on
machine on the same network — mini-PC, Raspberry Pi, NAS, old laptop, VM.

**Every path ends the same way:** open the web page it gives you, enter the
access key it printed, and you're controlling your AC.

### 🐧 Linux — add the package repo *(recommended)*

Self-contained packages (no Python needed) from the **signed repository** at
[bolero.salataputarica.hr.eu.org](https://bolero.salataputarica.hr.eu.org) —
installs *and updates* flow through apt/dnf/pacman/apk/opkg. Debian-family
example (the landing page has the others):

```bash
curl -fsSL https://bolero.salataputarica.hr.eu.org/breeze-core.asc \
  | sudo gpg --dearmor -o /usr/share/keyrings/breeze-core.gpg
echo "deb [signed-by=/usr/share/keyrings/breeze-core.gpg] https://bolero.salataputarica.hr.eu.org/deb stable main" \
  | sudo tee /etc/apt/sources.list.d/breeze-core.list
sudo apt update && sudo apt install breeze-core
```

Then:

```bash
sudo breeze-core pair                        # finds your units, writes the config
sudoedit /etc/breeze-core/breeze-core.env    # set BREEZE_HOST=<this machine's LAN IP>
sudo systemctl enable --now breeze-core      # start it (survives reboots)
```

…and open **`http://<BREEZE_HOST>:8420`**. Full per-distro instructions,
OpenWrt, Void/Gentoo/NixOS, and one-off downloads → **[docs/PACKAGES.md](docs/PACKAGES.md)**.

### 🪟 Windows

Download **`Breeze-Core-Setup.exe`** from the
[latest release](https://github.com/monikapurpl3/breeze-core/releases/latest)
and double-click — it installs the background service and offers to find your
units. Walkthrough → **[docs/WINDOWS.md](docs/WINDOWS.md)**.

### 🐳 Docker · 🍎 macOS · 😈 BSD · 🔧 from source

- **Docker** (if you already run containers): multi-arch image on GHCR → **[docs/DOCKER.md](docs/DOCKER.md)**.
- **macOS / FreeBSD**: from-source install with launchd / rc.d service → **[docs/INSTALL.md](docs/INSTALL.md)**.
- **From source on anything** (venv + your own service unit, every distro + non-systemd inits + musl) → **[docs/INSTALL.md](docs/INSTALL.md)**.

> **Reaching it from outside your home** (HTTPS over the internet)? Get it
> working locally first, then follow [docs/REVERSE-PROXY.md](docs/REVERSE-PROXY.md)
> (or the Windows Caddy wizard) — and read [HARDENING.md](HARDENING.md) before you expose anything.

---

## Documentation

| I want to… | Read |
|---|---|
| **Install** from native packages (deb/rpm/pacman/apk/opkg/flake/tarball) | [docs/PACKAGES.md](docs/PACKAGES.md) |
| **Install** from source, on any distro / init / libc, macOS, BSD | [docs/INSTALL.md](docs/INSTALL.md) |
| **Install** on Windows (installer, service, Caddy wizard, tripwire) | [docs/WINDOWS.md](docs/WINDOWS.md) |
| **Run** it as a container (image, compose, variants) | [docs/DOCKER.md](docs/DOCKER.md) |
| **Expose** it to the internet safely (nginx/Apache, TLS, fail2ban) | [docs/REVERSE-PROXY.md](docs/REVERSE-PROXY.md) + [HARDENING.md](HARDENING.md) |
| **Configure** it / call the **REST API** / understand **auth** | [docs/API.md](docs/API.md) |
| **Fix** something (errors, 401/403/500, CLIs, fail2ban) | [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) |
| **Package** it for a distro, or build the packages myself | [packaging/README.md](packaging/README.md) |
| Use the **Android app** | the [breeze](https://github.com/monikapurpl3/breeze) repo |

---

## Architecture

```
   Browser / Breeze app ─┐
                         │  HTTPS (via reverse proxy)  or  HTTP on the LAN
   ac-diag.zsh ──────────┤
                         ▼
              ┌─────────────────────────────┐
              │  uvicorn → meow_ac.app:app   │   (one worker + in-process scheduler)
              │   ├── /api/auth/*   pairing  │
              │   ├── /api/units*   control  │
              │   ├── /api/programs favourites/schedules/curves
              │   └── /  static web UI       │
              │            │ msmart-ng       │
              │            ▼                 │
              │   AC device objects (cached) │
              └────────────┬────────────────┘
                           │ TCP :6444 per unit
                    Midea AC units on the LAN
```

Inside the package, small layers are assembled by an app factory
(`create_app()` in `meow_ac/app.py`): **settings** (env) → **config**
(`config.json` store) → **security** (device-pairing auth) → **devices**
(connection lifecycle + wire schema) → **programs** (favourites / schedules /
temperature curves + a background scheduler) → **api** (router factories).
Connections are lazy and cached per unit; every read/write is a live LAN
round-trip. The full wire contract lives in [docs/API.md](docs/API.md).

---

## Web UI

Served by the app at `/`. Self-contained native ES modules — no build step,
no external dependencies. It prompts for the API key on first load (stored in
`localStorage`), runs the pairing flow, then shows a live control card per
unit. Manage units (add by IP / rename / remove), toggle °C/°F, and pick from
six **Material You-like colour palettes** (header 🎨, saved per browser); the
footer shows the server's version + build commit. Strict CSP — all styling in
`css/styles.css`, all logic in `js/` modules.

![Breeze Core web UI — colour palettes](docs/img/web-ui-palettes.png)

<sub>The palette picker. (All data shown is a non-representative example.)</sub>

---

## Security

Breeze Core is **LAN-first**. What the app enforces on its own: two-credential
access (enrollment key **+** per-device token — an
[RFC 8628-style pairing flow](docs/API.md#authentication-device-pairing)),
admin actions gated to the LAN, in-app rate limiting, strict security headers,
interactive docs disabled by default, and server-side input bounds. Before
exposing it to the internet, read **[HARDENING.md](HARDENING.md)** — the
threat model, the strongly-recommended VPN alternative, and the full go-live
runbook (TLS, rate limiting, fail2ban, egress lockdown, checklist).

---

## License

Breeze Core is **free software** under the GNU Affero General Public License
v3.0 ([AGPL-3.0](LICENSE)). No telemetry, no cloud callbacks after pairing.
You may run, study, share, and modify it; if you run a **modified** version as
a network service for others, AGPL §13 requires you to offer them your
modified source. All dependencies are permissive (MIT / BSD-3 / Apache-2.0).
The companion Android app, [breeze](https://github.com/monikapurpl3/breeze),
is AGPL-3.0 as well.
