# Security Policy

Breeze Core controls physical devices and, when exposed, faces the public internet — security reports are very welcome.

## Reporting a vulnerability

**Please report privately — do not open a public issue.**

Use GitHub's private vulnerability reporting: the repo's **Security** tab → **Report a vulnerability** (or [open a draft advisory](https://github.com/monikapurpl3/breeze-core/security/advisories/new)). Include:

- what the issue is and its impact,
- steps or a proof-of-concept to reproduce,
- affected version/commit and how you're running it (distro, behind nginx/Apache?, etc.).

Please give a reasonable window to fix before any public disclosure. There's no bounty — this is a hobby project — but credit is gladly given.

## Scope

In scope: the API/auth/enrollment logic, the scheduler, the web UI, privilege/isolation issues in the shipped systemd unit and docs, and anything that lets an unauthorized party read or control units.

Out of scope: issues that require an already-compromised host or LAN, self-inflicted misconfiguration contrary to [HARDENING.md](HARDENING.md), and vulnerabilities in third-party dependencies (report those upstream, but do tell us if we're using them unsafely).

## Hardening

If you're deploying Breeze Core publicly, **[HARDENING.md](HARDENING.md)** is the review + go-live checklist (TLS, rate limiting, fail2ban, systemd egress lockdown, admin-endpoint LAN gating). Following it closes the common exposure risks.

## Handling of secrets

Breeze Core stores only **hashes** of device tokens and pairing codes, compares secrets in constant time, keeps `config.json`/`devices.json` at mode 600, and has no telemetry or cloud callbacks after pairing.
