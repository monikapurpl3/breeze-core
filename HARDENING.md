# Hardening Breeze Core for public exposure

This is the security review and go-live runbook for taking Breeze Core off the LAN. The *mechanics* of setup live in [docs/INSTALL.md](docs/INSTALL.md) and [docs/REVERSE-PROXY.md](docs/REVERSE-PROXY.md); this document is the **why**, the threat model, and the checklist.

> **Status legend:** ✅ enforced by the app · ⚙️ you configure at deploy time · 💡 optional/further
>
> A VPN (WireGuard/Tailscale) sidesteps public exposure entirely and is worth a thought — but if you self-host you know the trade-offs. The rest of this document assumes you've chosen a deliberate public HTTPS endpoint.

---

## 1. Findings and mitigations

| # | Concern | Severity | Mitigation | Status |
|---|---------|----------|------------|--------|
| 1 | Cleartext credentials/control in transit | High | TLS at the reverse proxy (REVERSE-PROXY.md) + HSTS | ✅ header / ⚙️ TLS |
| 2 | A single shared secret on every request | High | Device-pairing: API key → *enrollment only*; per-device, revocable, hashed, expiring tokens | ✅ |
| 3 | Brute-forcing the pairing code / credentials | High | In-app rate limits on `/api/auth/*` + proxy `limit_req` + fail2ban (§3) | ✅ app / ⚙️ proxy |
| 4 | Framework docs/schema exposed | High | `/docs`, `/redoc`, `/openapi.json` disabled unless `AC_DOCS=1` | ✅ |
| 5 | Host-header spoofing | Med | `TrustedHostMiddleware` via `AC_TRUSTED_HOSTS` | ✅ code / ⚙️ set it |
| 6 | Missing response-security headers | Med | CSP / HSTS / nosniff / frame-deny middleware | ✅ |
| 7 | Unbounded control inputs reaching the device | Med | `ControlRequest` bounds (temp 16–30/0.5°, known fan speeds) → `422` | ✅ |
| 8 | X-Forwarded-For spoofing → fake "LAN" client | High | Proxy overwrites XFF with the real peer (`$remote_addr` / `%{REMOTE_ADDR}s`); admin check reads it | ⚙️ (REVERSE-PROXY.md) |
| 9 | Token/DoS via device round-trips | Med | Proxy rate-limit + timeouts + small `client_max_body_size` | ⚙️ |
| 10 | Compromised process reaching the internet | Low | systemd `IPAddressAllow` LAN+loopback / `IPAddressDeny=any` | ⚙️ (INSTALL §5) |
| 11 | Secrets at rest | Low | `config.json`/`devices.json` mode 600; tokens stored **hashed** only | ✅ |

Items marked ✅ are on by default in the app. ⚙️ items are the deploy-time work in the two guides.

---

## 2. Application settings for public exposure

Set in the systemd unit (details + proxy configs in [REVERSE-PROXY.md](docs/REVERSE-PROXY.md)):

```ini
Environment=AC_BEHIND_PROXY=1                 # trust X-Forwarded-For from the local proxy
Environment=AC_TRUSTED_HOSTS=breeze.example.com,127.0.0.1,localhost
Environment=AC_ENROLL_LAN_ONLY=1              # approvals only from a private/LAN address (default)
Environment=AC_TOKEN_TTL_DAYS=90              # device tokens expire; lower = tighter
# leave AC_DOCS unset so docs stay disabled
ExecStart=… uvicorn meow_ac.app:app --host 127.0.0.1 --port 8420 --proxy-headers --forwarded-allow-ips 127.0.0.1
```

> **The load-bearing interaction:** with `AC_ENROLL_LAN_ONLY=1`, approving a pairing requires the *real client IP* to be private. Behind a proxy that IP comes from `X-Forwarded-For`, so (a) uvicorn must trust it only from the proxy (`--forwarded-allow-ips`), and (b) the proxy must **overwrite** XFF with the real peer, never append — otherwise an outsider sets `X-Forwarded-For: 192.168.x.x` and walks past the check. Both proxy configs in REVERSE-PROXY.md do this correctly.

---

## 3. fail2ban

The app logs rejections and the proxy logs 4xx; fail2ban bans IPs that pile them up. Point the jails at your vhost's **dedicated access log** (e.g. give the Breeze vhost its own `access_log`/`CustomLog`). Two jails: a general one, and a **tripwire** — any non-LAN hit on an admin endpoint (the proxy answers 403) is by definition hostile.

`/etc/fail2ban/filter.d/breeze-core.conf`:
```ini
[Definition]
# NOTE: fail2ban strips the [timestamp] but LEAVES the empty '[]' in the
# line it matches. A failregex containing the date matches NOTHING — a
# silent failure. Verify any change with: fail2ban-regex <log> <filter>
failregex = ^<HOST> \S+ \S+ \[\] "[^"]*" (?:400|401|403|404|405|422|429)
ignoreregex =
```
`/etc/fail2ban/filter.d/breeze-core-tripwire.conf`:
```ini
[Definition]
failregex = ^<HOST> \S+ \S+ \[\] "(?:GET|POST|PUT|DELETE|PATCH|HEAD|OPTIONS) /api/auth/(?:enroll/approve|devices)[^"]*" 403
ignoreregex =
```
`/etc/fail2ban/jail.d/breeze-core.local` (set `logpath` and `ignoreip` for your LAN):
```ini
[breeze-core]
enabled = true
port    = http,https
filter  = breeze-core
logpath = /var/log/nginx/breeze.access.log
maxretry = 5
findtime = 600
bantime  = 86400
bantime.increment = true
bantime.maxtime   = 5w
ignoreip = 127.0.0.1/8 ::1 192.168.0.0/16

[breeze-core-tripwire]
enabled = true
port    = http,https
filter  = breeze-core-tripwire
logpath = /var/log/nginx/breeze.access.log
maxretry = 1
findtime = 86400
bantime  = 604800
bantime.increment = true
bantime.maxtime   = 8w
ignoreip = 127.0.0.1/8 ::1 192.168.0.0/16
```
```bash
sudo systemctl restart fail2ban
sudo fail2ban-client status breeze-core
```
Example filter/jail files ship in [`deploy/fail2ban/`](deploy/). `ignoreip` exempts your LAN so you can't lock yourself out; outsiders get no grace.

> **Second gotcha:** the web UI/app must not spray 401s or a legitimate remote user with an expired token would ban *themselves*. Breeze's UI pauses polling while re-pairing and while backgrounded — keep that behavior if you fork the client.

---

## 4. systemd sandbox & egress

The unit in [INSTALL.md §5](docs/INSTALL.md#5-install-the-systemd-service) already runs unprivileged with `ProtectSystem=strict`, a syscall filter, empty `CapabilityBoundingSet`, and — the high-value one — **`IPAddressAllow` limited to loopback + your LAN with `IPAddressDeny=any`**. That means even a fully compromised process cannot exfiltrate or attack anything beyond your AC units. Confirm with `systemd-analyze security breeze-core` (aim for a low score).

`MemoryDenyWriteExecute=true` is tempting but breaks some CPython builds — test before enabling.

---

## 5. The authentication model & residual risk

- **Enrollment key** (`api_key`): authorizes only *starting* enrollment — leaking it doesn't hand over the units.
- **Device pairing:** single-use ~60 s code, hashed and rate-limited, approved by an **admin on the LAN**.
- **Per-device token:** 256-bit, stored **hashed** (SHA-256), named, revocable, expiring; required *together with* the API key for all control.
- **Revocation:** `ac-approve.zsh revoke <token_id>` (or `DELETE /api/auth/devices/{id}`) kills one device instantly.

Residual, by design: a **stolen device token** is valid until it expires or is revoked — lower `AC_TOKEN_TTL_DAYS` and revoke lost devices. The Breeze app stores its token in Keystore-backed encrypted storage with `allowBackup=false`.

---

## 6. Go-live checklist

- [ ] VPN considered and consciously rejected (§0)
- [ ] App bound to `127.0.0.1`, `--proxy-headers --forwarded-allow-ips 127.0.0.1`
- [ ] Reverse proxy with valid TLS (Let's Encrypt), HTTP→HTTPS redirect, server tokens off
- [ ] Proxy **overwrites** `X-Forwarded-For` with the real peer (not append)
- [ ] Rate limiting active on `/` and `/api/auth/`
- [ ] Admin endpoints (`enroll/approve`, `devices`) gated to the LAN at the proxy **and** by the app
- [ ] `AC_BEHIND_PROXY=1`, `AC_TRUSTED_HOSTS` set, `AC_ENROLL_LAN_ONLY=1`, `AC_DOCS` unset (verify `curl …/openapi.json` → 404)
- [ ] Port 8420 **not** reachable from the LAN/internet (proxy talks to it on loopback)
- [ ] systemd egress locked to LAN + loopback; `systemd-analyze security` reviewed
- [ ] fail2ban jails active; filters verified with `fail2ban-regex`
- [ ] Enrolled a device end-to-end over the public URL, then revoked one and confirmed it stops working
- [ ] `config.json` / `devices.json` are mode 600, backed up off-box
- [ ] Consider `AC_TOKEN_TTL_DAYS` lower than the 90-day default

Bots *will* find the hostname (it's published in Certificate Transparency logs) — that's what the jails are for. Check `fail2ban-client status breeze-core-tripwire` after a week for your first catches.
