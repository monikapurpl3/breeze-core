[← Breeze Core](../README.md)

# Breeze Core on Windows

A first-class Windows deployment: Breeze Core runs as a hardened **Windows
service** (via the bundled [NSSM](https://nssm.cc/)), with an optional guided
**Caddy** reverse proxy for public HTTPS and a **fail2ban-style** IP banner.
There's a click-through **NSIS installer**, or you can drive the same
PowerShell scripts by hand.

**Contents:**
[1. Prerequisites](#1-prerequisites) ·
[2. Guided installer](#2-install--the-guided-installer-recommended) ·
[3. Manual install](#3-install--manually-no-installer) ·
[4. Day to day](#4-the-service-day-to-day) ·
[5. Caddy / public HTTPS](#5-expose-it-publicly-with-caddy) ·
[6. Tripwire](#6-brute-force-defence--the-tripwire-fail2ban-parity) ·
[7. Hardening notes](#7-hardening-notes) ·
[8. Uninstall](#8-uninstall) ·
[9. Build it yourself](#9-build-the-installer-yourself)

> **What you get, and the trade-off.** The service runs unprivileged
> (`LOCAL SERVICE`), keeps its state in a locked-down `%ProgramData%\breeze-core`,
> and is firewalled to the LAN. Windows has **no equivalent of the systemd
> kernel sandbox** (syscall filter, `IPAddressDeny`), so for an internet-facing
> box a systemd Linux host or a container is still the stronger option — but the
> pieces below recover the important parts (privilege drop, filesystem
> confinement, TLS, XFF-overwrite, and IP banning). See
> [HARDENING.md sec. 7](../HARDENING.md#7-hardening-without-systemd).

Everything here targets **Windows 10/11 / Server 2019+**, amd64. Run the
elevated (Administrator) steps from **PowerShell**.

---

## 1. Prerequisites

- **Python 3.11+** on `PATH` (`py -3 --version`). If missing:
  `winget install Python.Python.3.12` (or grab it from python.org — tick *Add
  to PATH*). The installer/scripts build a private virtualenv from it; they
  don't touch your global Python.
- **Administrator** rights (registering a service + firewall rules).
- Your **Midea units** already on WiFi (via the *NetHome Plus* app).
- Internet access **at install time** (to download Python deps and, if you use
  it, Caddy).

---

## 2. Install — the guided installer (recommended)

1. Download **`Breeze-Core-Setup.exe`** from the
   [latest release](https://github.com/monikapurpl3/breeze-core/releases) and run it
   (it asks for elevation).
2. On the **Components** page:
   - **Breeze Core server (Windows service)** — required. Copies the app, builds
     the venv, installs dependencies, and registers the hardened `BreezeCore`
     service (LAN-first bind, `LOCAL SERVICE`, LocalSubnet firewall rule).
   - **Caddy reverse proxy (guided setup)** — *optional and separate*. Tick it
     only if you're exposing Breeze Core to the internet; it just opts you into
     running the Caddy wizard at the end (you can also run it any time later
     from the Start menu).
3. On the **Finish** page:
   - **Pair my AC units now** — opens a console that runs discovery, writes
     `config.json`, and prints your **API key once** (save it!).
   - **Set up the Caddy reverse proxy now** — launches the
     [Caddy wizard](#5-expose-it-publicly-with-caddy) (only pre-ticked if you
     chose that component).

After pairing, start the service if it isn't already:

```powershell
nssm start BreezeCore      # or: Start-Service BreezeCore
```

Then open `http://<this-PC-LAN-IP>:8420` on the LAN, enter the API key, and pair
a client. Start-menu shortcuts are installed for pairing, the Caddy wizard, and
editing the service.

---

## 3. Install — manually (no installer)

Get the code (git clone or copy the tree) to e.g. `C:\Program Files\Breeze Core`,
then from an elevated PowerShell **in `deploy\windows`**:

```powershell
# 1. fetch the bundled service wrapper (NSSM) into .\vendor
powershell -ExecutionPolicy Bypass -File .\fetch-vendor.ps1

# 2. build the venv + register the hardened BreezeCore service (LAN-first)
powershell -ExecutionPolicy Bypass -File .\install-service.ps1 `
  -Action Install -InstallDir "C:\Program Files\Breeze Core" -Nssm .\vendor\nssm.exe

# 3. pair your units (writes config.json, prints the API key once)
$env:AC_CONFIG = "$env:ProgramData\breeze-core\config.json"
& "C:\Program Files\Breeze Core\venv\Scripts\python.exe" `
  "C:\Program Files\Breeze Core\setup_device.py"

# 4. start it
nssm start BreezeCore
```

`install-service.ps1` flags: `-BindHost <ip>` (default: auto-detected LAN IP),
`-Port 8420`, `-BehindProxy` (bind loopback + `--proxy-headers` + `AC_BEHIND_PROXY=1`),
`-LockEgress` (best-effort outbound lockdown, see [sec. 7](#7-hardening-notes)),
`-NoFirewall`, and `-Action Uninstall [-Purge]`.

---

## 4. The service, day to day

`BreezeCore` is an auto-start service wrapping
`venv\Scripts\uvicorn.exe meow_ac.app:app`:

```powershell
nssm start   BreezeCore
nssm stop    BreezeCore
nssm restart BreezeCore
nssm edit    BreezeCore          # GUI: account, args, environment
Get-Service  BreezeCore
```

- **Account:** `NT AUTHORITY\LocalService` (low privilege, no password).
- **State/logs:** `%ProgramData%\breeze-core\` — `config.json`, `devices.json`,
  `programs.json`, and `logs\service.log` (rotated). The folder's ACL is
  stripped of inheritance and granted only to SYSTEM, Administrators, and
  LOCAL SERVICE — the Windows analogue of `chmod 600`/`750`.
- **Restart:** NSSM restarts the process automatically if it exits.

> The service errors (HTTP 500) until you've paired — it needs `config.json`.
> Pair first (step 3 above or the installer's finish page), then start it.

---

## 5. Expose it publicly with Caddy

The **Caddy wizard** is the Windows counterpart of the Linux
`deploy/reverse-proxy-wizard.sh`. Caddy is a single binary with **automatic
HTTPS** (Let's Encrypt) — no certbot, no manual renewal.

```powershell
# preview everything first — writes nothing, downloads nothing:
powershell -ExecutionPolicy Bypass -File .\caddy-wizard.ps1 `
  -Domain breeze.example.com -Email you@example.com -DryRun

# then for real (add -SetupTripwire to also install the IP banner):
powershell -ExecutionPolicy Bypass -File .\caddy-wizard.ps1 `
  -Domain breeze.example.com -Email you@example.com -SetupTripwire
```

What it does:

1. **Downloads** the official Caddy binary (the reverse-proxy step is
   deliberately *not* bundled — it's a separate, optional choice).
2. Renders a **hardened Caddyfile** (`%ProgramData%\breeze-core\Caddyfile`) and
   `caddy validate`s it:
   - Automatic HTTPS + HTTP→HTTPS redirect.
   - HSTS + `nosniff` + `X-Frame-Options: DENY` + `Referrer-Policy` + COOP; the
     `Server` header is stripped. (The app sends its own strict CSP — Caddy
     never adds a second one.)
   - **X-Forwarded-For is the real client.** With no `trusted_proxies`
     configured, Caddy drops any client-sent (forged) `X-Forwarded-For` and sets
     it to the real peer — the overwrite [HARDENING.md](../HARDENING.md) requires
     so nobody can fake a "LAN" client. **Don't** add public ranges to
     `trusted_proxies`.
   - **Admin endpoints** (`/api/auth/enroll/approve`, `/api/auth/devices`) are
     `403`'d unless the caller is on the LAN — defence in depth with the app's
     own check, and the signal the tripwire watches.
3. **Rebinds** `BreezeCore` to `127.0.0.1` with `--proxy-headers` and
   `AC_BEHIND_PROXY=1` (so only Caddy can reach it). Pass `-KeepLanBind` to also
   keep it directly reachable on the LAN.
4. Registers **`BreezeCaddy`** as an auto-start service and opens inbound
   TCP **80/443**.
5. With `-SetupTripwire`, installs the banner (next section).

Point your domain's **A/AAAA** record at the host and forward **80/443** at your
router. Browse to `https://breeze.example.com` — Caddy fetches the certificate
on first hit. Walk the [go-live checklist](../HARDENING.md#6-go-live-checklist)
before you announce the hostname.

A static reference config is in
[`deploy/windows/Caddyfile.example`](../deploy/windows/Caddyfile.example) if you
prefer to hand-edit.

---

## 6. Brute-force defence — the tripwire (fail2ban parity)

Windows has no fail2ban, so `deploy/windows/breeze-tripwire.ps1` fills the gap.
It tails Caddy's JSON access log and bans abusive source IPs with **Windows
Firewall** block rules — the Windows analogue of the
[HARDENING.md sec. 3 jails](../HARDENING.md#3-fail2ban):

- **General:** ≥ 5 `4xx/5xx` from one IP within 10 min → 24 h ban.
- **Tripwire:** *any* `403` on an admin endpoint is hostile → 7-day ban.
- **LAN is never banned** (so you can't lock yourself out); bans expire
  automatically.

Enable it with the wizard's `-SetupTripwire`, or install it standalone as the
`BreezeTripwire` service. It needs rights to manage the firewall, so it runs as
`LocalSystem` (NSSM's default) — the only component that isn't `LocalService`.

```powershell
Get-NetFirewallRule -DisplayName "BreezeBan *"    # see who's currently banned
Get-Content "$env:ProgramData\breeze-core\logs\tripwire.log" -Tail 20
```

Tunable via parameters (`-MaxRetry`, `-FindWindowSec`, `-BanSec`,
`-TripwireBanSec`, `-LanCidr`).

---

## 7. Hardening notes

| systemd protection (Linux) | Windows equivalent here |
|---|---|
| Unprivileged `User=` | Service runs as `LOCAL SERVICE` |
| `ProtectSystem` / mode 600 | `%ProgramData%\breeze-core` ACL: inheritance off, SYSTEM/Admins/LocalService only |
| Inbound restricted to LAN | LocalSubnet-only firewall rule on the port (LAN mode) |
| TLS + HSTS + XFF-overwrite | Caddy auto-HTTPS + headers + default XFF overwrite |
| fail2ban jails | the `BreezeTripwire` watcher |
| `IPAddressDeny=any` (egress) | **weak point** — see below |

**Egress lockdown** is the one thing Windows can't do cleanly per-app. The
optional `install-service.ps1 -LockEgress` adds an outbound *block* rule for the
service's `python.exe` to `RemoteAddress Internet`, allowing only LAN/Intranet —
but Windows' "Internet" classification depends on the network-location profile
and isn't as tight as `IPAddressDeny`. Treat it as best-effort; verify your
units still respond after enabling it. For strict egress control, run Breeze
Core in a container or on a systemd Linux host.

---

## 8. Uninstall

Via **Apps & features → Breeze Core**, the Start-menu **Uninstall** shortcut, or
the scripts. Uninstalling removes the `BreezeCore` / `BreezeCaddy` /
`BreezeTripwire` services, their firewall rules, and the program files — but
**keeps** `%ProgramData%\breeze-core` (your config + device tokens). Delete that
folder by hand to wipe everything, or:

```powershell
powershell -ExecutionPolicy Bypass -File .\install-service.ps1 -Action Uninstall -Purge
```

---

## 9. Build the installer yourself

Requires [NSIS](https://nsis.sourceforge.io/) (`makensis`) and internet (for the
bundled NSSM). From `deploy\windows`:

```powershell
powershell -ExecutionPolicy Bypass -File .\fetch-vendor.ps1        # -> vendor\nssm.exe
& "C:\Program Files (x86)\NSIS\makensis.exe" /DVERSION=2.3.0 breeze-core-setup.nsi
# -> Breeze-Core-Setup.exe
```

`vendor\` and build output are git-ignored — no binaries are committed.

---

For a testing-only quick run without a service, see the short
[Windows note in INSTALL.md](INSTALL.md#windows). Next: the threat model and
go-live checklist in **[HARDENING.md](../HARDENING.md)**.
