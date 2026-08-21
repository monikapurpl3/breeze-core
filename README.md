<div align="center">

# Breeze Core

**Your air conditioner. Your network. No cloud.**

Self-hosted control for Midea air conditioners — a REST API, a web panel, and a
native Android app that talk to your units over your own LAN.

[![License](https://img.shields.io/badge/license-AGPL--3.0-blue)](LICENSE)
[![Latest release](https://img.shields.io/github/v/release/monikapurpl3/breeze-core?label=release)](https://github.com/monikapurpl3/breeze-core/releases/latest)
[![Packages](https://img.shields.io/badge/packages-deb%20·%20rpm%20·%20apk%20·%20pacman%20·%20opkg-6aa84f)](https://bolero.salataputarica.hr.eu.org)
[![Documentation](https://img.shields.io/badge/docs-wiki-8e7cc3)](https://github.com/monikapurpl3/breeze-core/wiki)

</div>

![Breeze Core web panel](docs/img/web-ui.png)

## Why

The vendor app sends "make it 23°" to a datacentre and back, to reach a machine
three metres away. Breeze Core cuts the round trip: after one local pairing there
is **no cloud dependency, no account, and no telemetry**. When your internet is
down, your air conditioning still works.

- **Control it from anywhere on your LAN** — browser, Android app, home-screen
  widgets, Android Auto, REST, `curl`, cron.
- **Automation that runs on the server.** Schedules and temperature curves fire
  whether or not your phone is home, charged, or awake.
- **Live, not polled.** Changes push to every client over SSE — yours, a
  schedule's, or another device's.
- **Quiet by default.** The beep is off unless a client asks for it, so a 3 a.m.
  setpoint change wakes nobody.
- **One credential per device**, each individually revocable, each approved from
  the LAN. No shared password to pass around the household.
- **Installs like software should** — signed repository, native packages for
  Linux, Windows, the BSDs, OpenWrt and OPNsense, and five container images.

## Install

**Linux** — add the signed repository and updates arrive through your package
manager:

```bash
curl -fsSL https://bolero.salataputarica.hr.eu.org/breeze-core.asc \
  | sudo gpg --dearmor -o /usr/share/keyrings/breeze-core.gpg
echo "deb [signed-by=/usr/share/keyrings/breeze-core.gpg] https://bolero.salataputarica.hr.eu.org/deb stable main" \
  | sudo tee /etc/apt/sources.list.d/breeze-core.list
sudo apt update && sudo apt install breeze-core

sudo breeze-core pair                     # finds your units, writes the config
sudo systemctl enable --now breeze-core    # start it, survives reboots
```

Then open `http://<server>:8420` and enter the key it printed.

**Everything else** — [Windows](https://github.com/monikapurpl3/breeze-core/wiki/Installing-on-Windows)
· [containers](https://github.com/monikapurpl3/breeze-core/wiki/Installing-with-containers)
· [OPNsense](https://github.com/monikapurpl3/breeze-core/wiki/Installing-on-OPNsense)
· [macOS, BSD, from source](https://github.com/monikapurpl3/breeze-core/wiki/Installing-from-source)
· [other distros and one-off downloads](https://bolero.salataputarica.hr.eu.org)

**Android app** — [Breeze](https://github.com/monikapurpl3/breeze), with widgets
and Android Auto.

## Documentation

Everything lives in the **[wiki](https://github.com/monikapurpl3/breeze-core/wiki)**:

|  |  |
|---|---|
| [First run and pairing](https://github.com/monikapurpl3/breeze-core/wiki/First-run-and-pairing) | getting from installed to controlling |
| [The web panel](https://github.com/monikapurpl3/breeze-core/wiki/The-web-panel) · [Programs, schedules, curves](https://github.com/monikapurpl3/breeze-core/wiki/Programs-schedules-and-curves) | using it day to day |
| [REST API](https://github.com/monikapurpl3/breeze-core/wiki/REST-API) · [Control schema](https://github.com/monikapurpl3/breeze-core/wiki/Control-schema) · [Configuration](https://github.com/monikapurpl3/breeze-core/wiki/Configuration) | writing a client, automating it |
| [Exposing it safely](https://github.com/monikapurpl3/breeze-core/wiki/Exposing-it-safely) · [Reverse proxy and TLS](https://github.com/monikapurpl3/breeze-core/wiki/Reverse-proxy-and-TLS) | reaching it from outside the house |
| [Troubleshooting](https://github.com/monikapurpl3/breeze-core/wiki/Troubleshooting) | when something is off |
| [Architecture](https://github.com/monikapurpl3/breeze-core/wiki/Architecture) · [Building and releasing](https://github.com/monikapurpl3/breeze-core/wiki/Building-and-releasing) | working on it |

## Honest limits

It needs a machine that is always on, and you are its sysadmin. Units join Wi-Fi
through the vendor app, and V3 units need **one** internet-connected discovery run
to fetch their credentials — everything after that is offline. Nothing is exposed
to the internet by default; away-from-home control means a VPN or a proxy you
secure yourself. The feature ceiling is your firmware's. The native app is
Android-only. It is one brand, one job — not a home-automation platform.

The full comparison with the vendor app, drawbacks included:
[Compared to NetHome Plus](https://github.com/monikapurpl3/breeze-core/wiki/Compared-to-NetHome-Plus).

## Security

Two credentials, never one: an enrolment key to *begin* pairing, and a per-device
credential — **Ed25519 request signing** by default, with the secret never on the
wire — to use the API. Admin actions are gated to the LAN, with rate limiting,
strict security headers, and interactive docs off by default. Before exposing
anything to the internet, read
**[Exposing it safely](https://github.com/monikapurpl3/breeze-core/wiki/Exposing-it-safely)**.

Found a vulnerability? [SECURITY.md](SECURITY.md) — privately, please.

## License

[AGPL-3.0](LICENSE). Free software: run it, study it, share it, change it. If you
run a modified version as a network service for others, §13 asks you to offer them
your changes. Built on [msmart-ng](https://github.com/mill1000/midea-msmart),
[FastAPI](https://fastapi.tiangolo.com/) and
[uvicorn](https://www.uvicorn.org/) — all permissively licensed.
