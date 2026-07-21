[← Breeze Core](README.md)

# Hardening Breeze Core for public exposure

This is the security review and go-live runbook for taking Breeze Core off the LAN. The *mechanics* of setup live in [docs/INSTALL.md](docs/INSTALL.md) and [docs/REVERSE-PROXY.md](docs/REVERSE-PROXY.md); this document is the **why**, the threat model, and the checklist.

**Contents:**
[1. Findings & mitigations](#1-findings-and-mitigations) ·
[2. App settings for public exposure](#2-application-settings-for-public-exposure) ·
[3. fail2ban](#3-fail2ban) ·
[4. systemd sandbox & egress](#4-systemd-sandbox--egress) ·
[5. Auth model & residual risk](#5-the-authentication-model--residual-risk) ·
[6. Go-live checklist](#6-go-live-checklist) ·
[7. Hardening without systemd](#7-hardening-without-systemd)

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
| 11 | Secrets at rest | Low | `config.json` mode 640 (owner rw, group r — for admin CLIs), `devices.json` mode 600; tokens stored **hashed** only | ✅ |

Items marked ✅ are on by default in the app. ⚙️ items are the deploy-time work in the two guides.

> **New in 2.4.0 — kept safe by design:** `GET /api/health` is the one unauthenticated route; it returns only `{"status":"ok"}` (no version, no counts) so it leaks nothing to anonymous callers. `GET /api/version` (which does report the build + feature list) sits behind the API key, same reasoning as keeping `/docs` off. **Response compression** (brotli/gzip) is on by default — safe because responses carry no secrets (the config view is sanitized; tokens are never returned), so BREACH doesn't apply; set `AC_COMPRESSION=0` if your proxy compresses instead.

---

## 2. Application settings for public exposure

Set in the systemd unit (details + proxy configs in [REVERSE-PROXY.md](docs/REVERSE-PROXY.md)):

```ini
Environment=AC_BEHIND_PROXY=1                 # trust X-Forwarded-For from the local proxy
Environment=AC_TRUSTED_HOSTS=breeze.example.com,127.0.0.1,localhost
Environment=AC_ENROLL_LAN_ONLY=1              # approvals only from a private/LAN address (default)
Environment=AC_TOKEN_TTL_DAYS=90              # device tokens expire; lower = tighter
# AC_MIN_AUTH_VERSION=2                        # once clients are on v2, refuse legacy v1 (426)
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

> **Not on systemd?** None of this section applies as-is — OpenRC/runit/s6/supervisord, the BSDs, and macOS have no equivalent of these directives. The egress lockdown especially is the highest-value protection, so don't skip it: **[§7 Hardening without systemd](#7-hardening-without-systemd)** shows how to recover the important parts (privilege drop, filesystem confinement, and an egress firewall) on those platforms.

---

## 5. The authentication model & residual risk

- **Enrollment key** (`api_key`): authorizes only *starting* enrollment — leaking it doesn't hand over the units.
- **Device pairing:** single-use ~60 s code, hashed and rate-limited, approved by an **admin on the LAN**.
- **Per-device credential** (required *together with* the API key for all control), named, revocable, expiring, in two profiles:
  - **v2 — Ed25519 request signing (recommended).** The server stores **only the public key**; each request is signed over method+path+timestamp+nonce+`SHA3-512(body)`. The secret never rides the wire, requests can't be replayed (nonce + ±60 s skew) or tampered, and **a `devices.json` leak exposes nothing forgeable** — the strongest posture.
  - **v1 — bearer token.** 256-bit, stored **hashed** (SHA-256). Still supported; the secret is sent on every request (TLS-protected).
- **Rollout clamp:** `AC_MIN_AUTH_VERSION` (default `1`) accepts both and nudges v1 clients (`X-Breeze-Upgrade` header); set it to `2` to refuse v1 with `426` once clients are updated. Enrolled v1 devices upgrade to v2 in place (`POST /api/auth/upgrade`) with no re-pairing.
- **Revocation:** `ac-approve.zsh revoke <token_id>` (or `DELETE /api/auth/devices/{id}`) kills one device instantly.

Residual, by design: a **stolen v1 bearer token** is valid until it expires or is revoked — prefer v2 (nothing reusable is transmitted or stored), lower `AC_TOKEN_TTL_DAYS`, and revoke lost devices. The Breeze app keeps its v2 private key in Keystore-backed encrypted storage with `allowBackup=false`. Note the bundled **web UI and CLIs are still v1** — migrate them before raising the clamp to `2`.

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
- [ ] Egress locked to LAN + loopback — systemd `IPAddressDeny` (`systemd-analyze security` reviewed) **or**, off systemd, the user-matched firewall rule from [§7](#7-hardening-without-systemd)
- [ ] Service runs as the unprivileged `breeze` user (not root) — verify `ps -o user= -p <pid>`
- [ ] fail2ban jails active; filters verified with `fail2ban-regex`
- [ ] Enrolled a device end-to-end over the public URL, then revoked one and confirmed it stops working
- [ ] `config.json` is mode 640 (group-readable for admins in the service group) and `devices.json` is mode 600; both backed up off-box; the state dir is 750 so neither is world-readable
- [ ] Consider `AC_TOKEN_TTL_DAYS` lower than the 90-day default

Bots *will* find the hostname (it's published in Certificate Transparency logs) — that's what the jails are for. Check `fail2ban-client status breeze-core-tripwire` after a week for your first catches.

---

## 7. Hardening without systemd

The §4 sandbox is systemd-only. On OpenRC / runit / s6 / supervisord / SysV, the BSDs, or macOS you install Breeze Core the same way (see [INSTALL.md](docs/INSTALL.md)) but must recover the protections yourself. In descending order of importance:

| systemd directive (§4/§5) | What it buys | Non-systemd equivalent |
|---|---|---|
| `IPAddressAllow`/`IPAddressDeny` | Compromised process can't phone home | **Firewall egress rule matching the service *user*** (below) — the single most important one |
| `User=` / `CapabilityBoundingSet=` / `NoNewPrivileges` | No root, no privilege escalation | Run as the unprivileged `breeze` account (all the init templates do); never root; no setuid |
| `ProtectSystem=strict` / `ReadWritePaths` / `ProtectHome` | Read-only FS except state dir | Tight ownership + a container read-only rootfs or a **FreeBSD jail** / **chroot** |
| `SystemCallFilter` / `RestrictAddressFamilies` | Kernel-attack-surface reduction | No portable equivalent — a **container** (default seccomp profile) is the practical way to get it |
| `Restart=on-failure` | Survives crashes | Your supervisor's respawn (`supervise-daemon`, runit, `autorestart=true`, `daemon -r`) |

### The egress lockdown (do this one)

Restrict the **service user's** outbound traffic to loopback + your LAN, so even a fully compromised process can only reach your AC units. Match on the `breeze` UID so the rest of the box is unaffected.

**Linux — nftables** (`/etc/nftables.conf`, or your init's firewall step):
```nft
table inet breeze {
  chain output {
    type filter hook output priority 0; policy accept;
    meta skuid "breeze" oif "lo" accept
    meta skuid "breeze" ip daddr 192.168.0.0/16 accept   # your LAN CIDR
    meta skuid "breeze" ip6 daddr ::1 accept
    meta skuid "breeze" drop                              # nothing else leaves
  }
}
```
**Linux — iptables** (older boxes):
```sh
iptables -A OUTPUT -m owner --uid-owner breeze -o lo -j ACCEPT
iptables -A OUTPUT -m owner --uid-owner breeze -d 192.168.0.0/16 -j ACCEPT
iptables -A OUTPUT -m owner --uid-owner breeze -j REJECT
```
**FreeBSD/macOS — pf** (`/etc/pf.conf`; discovery needs UDP too):
```pf
lan = "192.168.0.0/16"
pass  out on lo0 user breeze
pass  out proto { tcp udp } from any to $lan user breeze
block out user breeze                                    # default-deny the rest
```
Verify: as the `breeze` user, an outbound connection to a public address should fail while a unit on the LAN still responds.

### Filesystem & privilege

- **Unprivileged user, always.** Every template in [`deploy/init/`](deploy/init/) drops to `breeze` (`command_user` / `chpst -u` / `s6-setuidgid` / `user=` / `--chuid` / `daemon -u`). Confirm with `ps -o user= -p <pid>`.
- **Least-writable state.** Only `/etc/breeze-core` (or your chosen state dir) needs write access, owned by `breeze`, mode `750`; `config.json` mode `640` (group-readable so admins you add to the `breeze` group can run the CLIs), `devices.json` mode `600`. The 750 dir means "group" is only the service account + admins you add, never other local users. Everything else the process touches should be read-only to it.
- **Strongest containment:** run it in a **container with a read-only rootfs** (`docker run --read-only --tmpfs /tmp --cap-drop ALL`, only `/etc/breeze-core` writable — see [DOCKER.md](docs/DOCKER.md)) or a **FreeBSD jail**. Either recovers most of what §4 gives you on systemd, on any host.

### Everything else is unchanged

TLS + reverse proxy (§2, REVERSE-PROXY.md), the XFF-overwrite rule, fail2ban (§3), the two-credential auth model (§5), and the app-enforced items in §1 are all init-independent. Only §4 needed translating.

> If you're doing public exposure without systemd, seriously consider the **container** path: it hands you privilege drop, a read-only rootfs, a seccomp profile, and network scoping in one place, and the same image runs everywhere.

### Windows

Windows is its own non-systemd case with a complete runbook in
[docs/WINDOWS.md](docs/WINDOWS.md); the mapping to this document:

- **Privilege drop** — the `BreezeCore` service runs as `LOCAL SERVICE`; state in `%ProgramData%\breeze-core` has inheritance stripped and is granted only to SYSTEM/Administrators/LocalService (the `chmod 600`/`750` analogue).
- **TLS + headers + XFF overwrite (§2, §8)** — the bundled **Caddy** wizard does auto-HTTPS + HSTS/headers. Caddy needs *no* explicit XFF rule: with no `trusted_proxies` configured it drops a client-sent `X-Forwarded-For` and substitutes the real peer (verified), which *is* the overwrite. Never add public ranges to `trusted_proxies`.
- **fail2ban (§3)** — the `BreezeTripwire` watcher tails Caddy's access log and bans IPs via Windows Firewall (general 4xx/5xx flood + instant admin-`403` tripwire; LAN never banned; bans expire). It must manage the firewall, so it — and only it — runs as LocalSystem.
- **Egress lockdown (§4 item 10)** — the weak spot. Windows Firewall can't cleanly default-deny per-app egress; `install-service.ps1 -LockEgress` adds a best-effort "block this binary to `Internet`" rule, but classification is profile-dependent. For strict egress, run the container image or a systemd Linux host instead.
- **Syscall filter / seccomp** — no equivalent; use the container image if you need it.
