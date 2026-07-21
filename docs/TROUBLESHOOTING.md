[← Breeze Core](../README.md)

# Troubleshooting & diagnostic tools

**First stops, in order:**

1. `curl -s http://<host>:8420/api/health` — no auth; should print `{"status":"ok"}`.
2. `curl -H "X-API-Key: <key>" http://<host>:8420/api/version` — confirms the key and shows version/features.
3. The logs — `journalctl -u breeze-core -f`, or the Docker / NSSM / procd logs.
4. The [diagnostic CLI](#the-diagnostic--approval-clis): `tools/ac-diag.zsh … --auto` runs the whole battery below in one go.

---

## Common problems

### `ac-approve` / `ac-diag`: "can't read config.json — run with sudo, or join the group"

The CLIs read `config.json` for the API key. It's mode **640**
(group-readable), so the fix is to add your admin user to the service group
**once**, then **log out and back in** (group membership only applies to new
logins):

```bash
sudo usermod -aG breeze "$USER"   # use your service group; re-login afterward
id                                # confirm the group shows up
```

After that, run the tool **without `sudo`**.

**Don't `sudo acapprove`** (→ `sudo: acapprove: command not found`). If
`acapprove` is a shell **alias**, `sudo` starts a fresh shell that has neither
your aliases nor your group — so it can't find the command *and* couldn't
read the config anyway. If you truly need root, call the script by its real
path:

```bash
sudo zsh /opt/breeze-core/tools/ac-approve.zsh \
  --base-url http://127.0.0.1:8420 --config /etc/breeze-core/config.json approve <CODE>
```

Pairing codes are short-lived (~60 s) — if approval says the code is
unknown/expired, just start pairing again from the client.

### The API returns 500, or a message telling you to run `setup_device.py`

The service is up but not paired yet — `config.json` has no `api_key`/units.
Run `setup_device.py` / `breeze-core pair` (see
[INSTALL.md](INSTALL.md#4-discover-and-pair-your-units)) to discover units
and mint the key, then restart the service. The static UI at `/` still loads;
only the API needs a config.

### Enrollment fails with a 500 / `PermissionError` writing `devices.json`

The runtime dir must be owned by the service user (it writes
`devices.json`/`programs.json` there) — a root-owned dir makes those writes
fail:

```bash
sudo chown -R breeze:breeze /etc/breeze-core
sudo chmod 750 /etc/breeze-core && sudo chmod 640 /etc/breeze-core/config.json
```

### Pairing/approval returns 500 on RHEL/Fedora/Alma (SELinux) — reads work, writes don't

If the packaged service can *read* its config but every write to
`/etc/breeze-core` (approving a pairing, saving programs) dies with a
`PermissionError` — and there's no AVC in the audit log — check the service's
SELinux domain:

```bash
ps -o label= -p "$(systemctl show breeze-core -p MainPID --value)"
```

If it says `init_t` instead of `unconfined_service_t`, the executable under
`/usr/lib/breeze-core/` is labeled `lib_t`, which is not a domain-transition
entrypoint (denials from `init_t` are *dontaudit*'d — hence the silence).
Packages since **2.6.1** fix this in their post-install; on an older install:

```bash
sudo semanage fcontext -a -t bin_t "/usr/lib/breeze-core/breeze-core"
sudo restorecon /usr/lib/breeze-core/breeze-core
sudo systemctl restart breeze-core
```

### Every request gets 401

The per-device token is missing or expired (separate from the API key).
Re-pair the device — the web UI and app do this automatically on a 401. Tune
lifetime with `AC_TOKEN_TTL_DAYS`.

### Approving from the LAN still gives 403 ("admin action must come from the LAN")

Approval must originate from a private IP. **Behind a reverse proxy**, every
request looks like `127.0.0.1` unless you forward the real client: set
`AC_BEHIND_PROXY=1`, run uvicorn with
`--proxy-headers --forwarded-allow-ips 127.0.0.1`, and make the proxy
**overwrite** `X-Forwarded-For` with the real peer (nginx `$remote_addr`;
Caddy does this by default with no `trusted_proxies`). Appending XFF is
spoofable — see [HARDENING.md](../HARDENING.md).

### Can't reach `:8420`

Behind a proxy the app binds **loopback only** by design — use the proxied
HTTPS URL, not `:8420`. On the LAN, check the bind address (a LAN IP, not
`0.0.0.0`) and that the firewall allows 8420 from your subnet
([INSTALL.md §6](INSTALL.md#6-open-the-firewall-lan-only)).

### "Scan the network" finds nothing (app or web UI)

`GET /api/units/scan` (Breeze Core ≥ 3.0.0) TCP-scans ports 6440–6449 across
the server's own private `/24`. If it comes up empty:

- **Wrong subnet.** It autodetects the server's primary private network; a
  multi-homed host or an unusual layout may guess wrong. Pass an explicit
  CIDR: `GET /api/units/scan?subnet=192.168.1.0/24`.
- **Behind a reverse proxy / loopback bind.** The scan uses the *server's*
  own LAN interface (not where uvicorn binds), so it still works behind nginx
  — but if the box genuinely isn't on the units' L2 network (e.g. a different
  VLAN), it can't see them. Add by IP instead.
- **Firewalled units.** Some firmware only answers on `6444`; a host firewall
  between the server and the units will hide them. The manual *add by IP*
  path still works (it runs real discovery).
- **Non-private target refused.** The scanner only scans RFC-1918 ranges and
  caps the host count — it will 400 on a public or oversized `subnet`.

### fail2ban locked me out

Add your LAN to `ignoreip`; don't let a client spray 401s (an expired token
repeated across many units can trip a jail).

### Windows: service won't start / SmartScreen warning

The service errors until you've paired (run *Pair AC units* first).
SmartScreen warns on the unsigned installer → *More info → Run anyway*. See
[WINDOWS.md](WINDOWS.md).

### Docker finds no units

Discovery (UDP broadcast) needs `--network host`; a bind-mounted state dir
must be writable by UID 1001 (`chown 1001:0`). See [DOCKER.md](DOCKER.md).

---

## The diagnostic & approval CLIs

They come in two equivalent forms — pick whichever your install has:

- **Built into the binary/packages** (v2.6.0+): `breeze-core diag`,
  `breeze-core approve <CODE>`, `breeze-core devices`,
  `breeze-core revoke <token_id>` — same flags as the zsh tool below
  (`--auto`, `--unit`, `--base-url`, `--config`, `--token`, `--pair`,
  `--no-pair`, `--forget-token`, `--with-control-test`). On a source or
  Windows install the same commands are available as
  `python -m meow_ac.cli diag …`.
- **The original zsh scripts** (`tools/ac-diag.zsh`, `tools/ac-approve.zsh`)
  for source installs — zero dependencies beyond `zsh`, `curl`, `jq`.

Both forms speak only HTTP (they never touch the server's internals), read
`config.json` for the key, and share the same device-token cache
(`~/.config/ac-diag/token`), so pairing once covers both.

**`ac-diag.zsh`** checks, in one run: connectivity (`/api/health`), **server
version + build commit + advertised features** (`/api/version`), the auth
posture (rejects no-key/wrong-key, and detects whether the control API is
token-gated), **paired devices** with expiry warnings, **config
secret-sanitisation** (asserts `/api/config` leaks no key/token), the
**batch-state** endpoint, **input-validation** (unknown-unit → 404,
out-of-range control → 422), per-unit state/latency/enum checks, and the
**scheduler + programs** status.

Because control/config/programs routes need a **device token** as well as the
key, the tool obtains one automatically: it self-enrols on the LAN (start →
approve → poll, all key-authenticated) and caches the token under
`~/.config/ac-diag/` — or pass `--token`, set `$AC_DIAG_TOKEN`, or `--pair`
to re-mint. The minted token shows up as `ac-diag` in `ac-approve list` and
is revocable.

```bash
# full read-only diagnostic on every unit (self-pairs on the LAN if needed)
./tools/ac-diag.zsh --base-url http://<host>:8420 --config /etc/breeze-core/config.json --auto

# just one unit (by id or name), or an interactive menu with no args
./tools/ac-diag.zsh --unit "Living Room"
./tools/ac-diag.zsh --token <DEVICE_TOKEN>     # use a token you already have
./tools/ac-diag.zsh --forget-token             # drop the cached token

# approve a pairing code / list / revoke (run on the LAN)
./tools/ac-approve.zsh --base-url http://<host>:8420 --config /etc/breeze-core/config.json approve <CODE>
./tools/ac-approve.zsh --base-url http://<host>:8420 --config /etc/breeze-core/config.json list
```
