# Installing Breeze Core

This installs Breeze Core as a hardened **systemd service** on a Linux host on the same LAN as your Midea units. It's LAN-only by default; to reach it from outside your network, do this first, then follow [REVERSE-PROXY.md](REVERSE-PROXY.md).

> **Not on systemd? Not on glibc?** The application is the same everywhere — `uvicorn meow_ac.app:app` with a few env vars — only *how you supervise it* and *how you install the Python deps* change. Sections 1–4 (packages, user, venv, pairing) apply to every OS; then jump to your platform instead of section 5:
> **[non-systemd init](#running-without-systemd-openrc-runit-s6-supervisord-sysv)** (OpenRC / runit / s6 / supervisord / SysV) · **[non-glibc / musl](#non-glibc-musl-libc-systems)** (Alpine, Void-musl) · **[FreeBSD/BSD](#freebsd-and-other-bsds)** · **[macOS](#macos)** · **[NixOS](#nixos-declarative)** · **[Windows](WINDOWS.md)** / **[WSL](#wsl-windows-subsystem-for-linux)**. The one thing only systemd gives you out of the box is the kernel-level sandbox (§5) — [HARDENING.md](../HARDENING.md#7-hardening-without-systemd) shows how to recover the equivalents elsewhere.

The layout we build (all paths are conventions — change them freely, they're wired via env vars):

```
/opt/breeze-core/        the code + a Python virtualenv (venv/)
/etc/breeze-core/        config.json, devices.json, programs.json  (owned by the service user)
/etc/systemd/system/breeze-core.service
service user:            breeze  (system account, no login, no home)
```

> The one fixed technical name is the ASGI entry point **`meow_ac.app:app`** (the Python package is `meow_ac`). Everything else below is your choice.

Jump to your distro for packages and firewall, then follow the common steps:
[RHEL & compatibles](#1a-rhel--compatibles) · [Debian & compatibles](#1b-debian--compatibles) · [openSUSE / SLES](#1c-opensuse--sles) · [Arch & others](#1d-arch--other-distros) · [NixOS](#nixos-declarative) · then [common setup](#2-create-the-service-user-and-directories).

---

## 1. Install system packages

You need **Python 3.11+**, `pip`, the `venv` module, and `git`. Optional: `curl`, `jq`, `zsh` for the diagnostic/approval CLIs.

### 1a. RHEL & compatibles
*(RHEL, AlmaLinux, Rocky, CentOS Stream, Fedora, Oracle Linux)*

```bash
sudo dnf install -y python3 python3-pip git
# optional CLIs:
sudo dnf install -y curl jq zsh
```
- Check the version: `python3 --version`. If your release ships older than 3.11 (e.g. RHEL 8 → 3.6), install a newer stream: `sudo dnf install -y python3.11 python3.11-pip` and use `python3.11` in the commands below.
- **Extra that helps:** RHEL-family ships **SELinux enforcing** — a real plus. See [SELinux](#selinux-rhel-fedora-suse) below; you'll just need a `restorecon` after copying files.

### 1b. Debian & compatibles
*(Debian, Ubuntu, Linux Mint, Pop!_OS, Raspberry Pi OS, Armbian)*

```bash
sudo apt update
sudo apt install -y python3 python3-venv python3-pip git
# optional CLIs:
sudo apt install -y curl jq zsh
```
- `python3-venv` is a **separate package** on Debian/Ubuntu and is required — don't skip it.
- **Extra that helps:** Debian/Ubuntu ship **AppArmor**. systemd sandboxing (in our unit) is the primary defense, but you can add an AppArmor profile — see [AppArmor](#apparmor-debianubuntu-suse).

### 1c. openSUSE / SLES
*(openSUSE Leap, Tumbleweed, SUSE Linux Enterprise)*

```bash
sudo zypper refresh
sudo zypper install -y python3 python3-pip git
# optional CLIs:
sudo zypper install -y curl jq zsh
```
- Tumbleweed tracks recent Python; on Leap/SLES confirm `python3 --version` ≥ 3.11 (else install a `python311` package).
- **Extra that helps:** SUSE ships **firewalld** and **AppArmor** — both covered below.

### 1d. Arch & other distros

```bash
# Arch / Manjaro:
sudo pacman -S --needed python git
# Alpine (uses OpenRC, not systemd — see the note at the end):
sudo apk add python3 py3-pip git
# Void, Gentoo, etc.: install python (3.11+), pip, venv-capable python, git.
```

Then continue with the common steps below. (**NixOS** users: skip sections 1–5 and use the [declarative section](#nixos-declarative) instead.)

---

## 2. Create the service user and directories

A dedicated, loginless system account limits blast radius.

```bash
# the nologin path differs by distro; this finds it:
NOLOGIN="$(command -v nologin || echo /usr/sbin/nologin)"
sudo useradd --system --no-create-home --shell "$NOLOGIN" breeze

sudo mkdir -p /opt/breeze-core /etc/breeze-core
```

---

## 3. Get the code, create a virtualenv, install dependencies

```bash
# put the tree in /opt/breeze-core (git clone, or copy/scp it there)
sudo git clone <repo-url> /opt/breeze-core
cd /opt/breeze-core

sudo python3 -m venv venv
sudo ./venv/bin/pip install --upgrade pip
sudo ./venv/bin/pip install -r requirements.txt
```

> **Air-gapped / offline hosts:** `pip download -r requirements.txt` on an internet-connected machine of the same OS/arch, copy the wheels over, and `pip install --no-index --find-links ./wheels -r requirements.txt`.
>
> **Non-glibc (musl) hosts — Alpine, Void-musl, etc.:** pip normally pulls prebuilt **glibc** (manylinux) wheels for the native deps (`pydantic-core`, `cryptography`, `aiohttp`), which **won't load on musl libc**. Recent versions of those deps also publish **musllinux** wheels, so an up-to-date pip usually just works — but if you hit an `ImportError`/`Error loading shared library` or pip starts compiling, you need build tools first. See **[Non-glibc (musl libc) systems](#non-glibc-musl-libc-systems)** below before running the `pip install`.

---

## 4. Discover and pair your units

Run as a user that can send UDP broadcasts (root is simplest). This writes `config.json` and prints an **API key once** — save it.

```bash
sudo AC_CONFIG=/etc/breeze-core/config.json \
  /opt/breeze-core/venv/bin/python /opt/breeze-core/setup_device.py
```

- It broadcasts and should find every powered-on unit. Re-run later (or `--ip 192.168.1.73`) to add ones that were off; it merges by device id and keeps the API key.
- Now hand ownership of the runtime directory to the service user. **The directory must be owned by `breeze`, not just `config.json`** — the service writes `devices.json`/`programs.json` there, and a root-owned directory makes those writes fail:

```bash
sudo chown -R breeze:breeze /etc/breeze-core /opt/breeze-core
sudo chmod 750 /etc/breeze-core
sudo chmod 640 /etc/breeze-core/config.json   # group-readable (see below)
```

> **Running the CLIs as yourself (no sudo).** The diagnostic/approval tools
> (`tools/ac-*.zsh`) read `config.json` directly for the API key. `config.json`
> is mode **640**, so add your admin user to the service group once, then
> **log out and back in** — after that the tools work without `sudo`:
> ```bash
> sudo usermod -aG breeze "$USER"   # then re-login for it to take effect
> ```
> The state dir is `750`, so "group" is only the service account + admins you
> add. Don't run the tools via `sudo` if they're shell aliases — `sudo` drops
> your aliases *and* your group membership. See [Troubleshooting](../README.md#troubleshooting).

---

## 5. Install the systemd service

Create `/etc/systemd/system/breeze-core.service`. Replace `192.168.1.10` with **this host's LAN IP** (bind the LAN interface, not `0.0.0.0`). If you'll put it behind a reverse proxy, bind `127.0.0.1` instead and see [REVERSE-PROXY.md](REVERSE-PROXY.md).

```ini
[Unit]
Description=Breeze Core - self-hosted Midea AC control
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=breeze
Group=breeze
WorkingDirectory=/opt/breeze-core
Environment=AC_CONFIG=/etc/breeze-core/config.json
Environment=AC_DEVICES=/etc/breeze-core/devices.json
Environment=AC_PROGRAMS=/etc/breeze-core/programs.json
ExecStart=/opt/breeze-core/venv/bin/uvicorn meow_ac.app:app --host 192.168.1.10 --port 8420
Restart=on-failure
RestartSec=5

# --- sandboxing (works on any recent systemd) ---
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/etc/breeze-core
PrivateTmp=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
RestrictRealtime=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
RemoveIPC=true
SystemCallFilter=@system-service
SystemCallArchitectures=native
CapabilityBoundingSet=
LockPersonality=true
# Egress lockdown: the service only needs to reach your AC units. Restrict
# outbound to loopback + your LAN so a compromise can't phone home. Adjust
# the CIDR to your network (drop these two lines if your systemd is old).
IPAddressAllow=127.0.0.0/8 ::1/128 192.168.0.0/16
IPAddressDeny=any

[Install]
WantedBy=multi-user.target
```

Enable and start:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now breeze-core
systemctl status breeze-core
# check the sandbox score (lower is better):
systemd-analyze security breeze-core
```

Logs: `journalctl -u breeze-core -f`. Verify: `curl -s -o /dev/null -w '%{http_code}\n' -H 'X-API-Key: WRONG' http://192.168.1.10:8420/api/units` should print `401`.

---

## 6. Open the firewall (LAN only)

Allow port 8420 **only from your LAN**. Pick your firewall:

### firewalld (RHEL/Fedora/SUSE)
```bash
# if your LAN interface is already in the 'internal'/'home' zone:
sudo firewall-cmd --permanent --zone=internal --add-port=8420/tcp
# otherwise, allow just your subnet:
sudo firewall-cmd --permanent --zone=internal --add-source=192.168.0.0/16
sudo firewall-cmd --reload
```

### ufw (Debian/Ubuntu)
```bash
sudo ufw allow from 192.168.0.0/16 to any port 8420 proto tcp
sudo ufw reload
```

### nftables (generic)
```nft
# /etc/nftables.conf — inside your inet filter input chain:
tcp dport 8420 ip saddr 192.168.0.0/16 accept
tcp dport 8420 drop
```
```bash
sudo systemctl enable --now nftables && sudo nft -f /etc/nftables.conf
```

---

## 7. Distro-specific hardening extras

### SELinux (RHEL, Fedora, SUSE)
SELinux is a big win — keep it **enforcing** (`getenforce`). Two things to know:

- After copying files into `/opt/breeze-core` and `/etc/breeze-core`, restore their contexts:
  ```bash
  sudo restorecon -Rv /opt/breeze-core /etc/breeze-core
  ```
- The service runs as `unconfined_service_t` by default, which is allowed to bind ports and reach the LAN — so no port labeling is normally needed. If you *confine* the service or bind an unusual port and hit denials, check `sudo ausearch -m avc -ts recent` and, if needed, label the port:
  ```bash
  sudo semanage port -a -t http_port_t -p tcp 8420   # requires policycoreutils-python-utils
  ```

### AppArmor (Debian/Ubuntu, SUSE)
systemd sandboxing (section 5) is the primary containment. For an extra layer, you can add an AppArmor profile for the uvicorn binary. Minimal starting point at `/etc/apparmor.d/breeze-core`:
```
#include <tunables/global>
profile breeze-core /opt/breeze-core/venv/bin/python3 flags=(complain) {
  #include <abstractions/base>
  #include <abstractions/python>
  /opt/breeze-core/** r,
  /etc/breeze-core/** rw,
  network inet stream,
  network inet6 stream,
}
```
```bash
sudo apparmor_parser -r /etc/apparmor.d/breeze-core     # start in complain mode, then flip to enforce
```
(Only pursue this if you want defense-in-depth beyond the systemd unit.)

### Everywhere
- Keep the systemd sandbox directives from section 5 — they're distro-independent.
- Back up `/etc/breeze-core/` (config + token hashes + programs) off-box.
- Keep dependencies current: `sudo ./venv/bin/pip install -U -r requirements.txt` then `systemctl restart breeze-core`.

---

## NixOS (declarative)

On NixOS you don't create users or drop files imperatively — you declare it. Two wrinkles: Breeze Core isn't in nixpkgs, and **manylinux pip wheels (e.g. `pydantic-core`) won't run on NixOS** without help. Pick one approach:

**Approach A — nixpkgs Python env (recommended, pure).** Build the Python deps from nixpkgs so native pieces are linked correctly, and only fetch `msmart-ng` (not in nixpkgs) via an overlay. Sketch for `configuration.nix`:

```nix
{ config, pkgs, lib, ... }:
let
  # msmart-ng from PyPI (adjust version/hash):
  msmart-ng = pkgs.python312Packages.buildPythonPackage rec {
    pname = "msmart-ng"; version = "2026.7.0"; format = "pyproject";
    src = pkgs.fetchPypi { inherit pname version; sha256 = lib.fakeSha256; };
    nativeBuildInputs = [ pkgs.python312Packages.setuptools ];
    propagatedBuildInputs = with pkgs.python312Packages; [ aiohttp cryptography ];
  };
  pyEnv = pkgs.python312.withPackages (ps: [ ps.fastapi ps.uvicorn ps.pydantic msmart-ng ]);
  src = pkgs.fetchgit { url = "<repo-url>"; rev = "main"; sha256 = lib.fakeSha256; };
in {
  users.users.breeze = { isSystemUser = true; group = "breeze"; };
  users.groups.breeze = {};

  systemd.tmpfiles.rules = [ "d /etc/breeze-core 0750 breeze breeze -" ];

  systemd.services.breeze-core = {
    description = "Breeze Core";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ]; wants = [ "network-online.target" ];
    environment = {
      AC_CONFIG = "/etc/breeze-core/config.json";
      AC_DEVICES = "/etc/breeze-core/devices.json";
      AC_PROGRAMS = "/etc/breeze-core/programs.json";
    };
    serviceConfig = {
      User = "breeze"; Group = "breeze";
      WorkingDirectory = "${src}";
      ExecStart = "${pyEnv}/bin/uvicorn meow_ac.app:app --host 192.168.1.10 --port 8420";
      Restart = "on-failure";
      # same sandbox directives as the systemd unit above:
      NoNewPrivileges = true; ProtectSystem = "strict"; ProtectHome = true;
      ReadWritePaths = [ "/etc/breeze-core" ];
      PrivateTmp = true; RestrictAddressFamilies = "AF_INET AF_INET6 AF_UNIX";
      SystemCallFilter = "@system-service"; CapabilityBoundingSet = "";
      IPAddressAllow = "127.0.0.0/8 ::1/128 192.168.0.0/16"; IPAddressDeny = "any";
    };
  };

  networking.firewall.extraInputRules = ''
    ip saddr 192.168.0.0/16 tcp dport 8420 accept
  '';
}
```
Replace `lib.fakeSha256` with real hashes (`nix build` will tell you the correct ones). Run `setup_device.py` once from `nix shell nixpkgs#python312 -c ${pyEnv}/bin/python /path/setup_device.py` to create `/etc/breeze-core/config.json`.

**Approach B — nix-ld + venv (quick, impure).** Enable `programs.nix-ld.enable = true;`, then create a normal `venv` under `/etc/breeze-core/venv` and `pip install -r requirements.txt` as in sections 3–4; nix-ld lets the manylinux wheels find a dynamic linker. Point the systemd `ExecStart` at that venv's uvicorn. Simpler to get going, but not fully declarative.

**Extra that helps (NixOS):** the whole thing is reproducible and the store is immutable — pin the repo `rev` and dep versions in your flake and your deployment is byte-for-byte rebuildable.

---

## Running without systemd (OpenRC, runit, s6, supervisord, SysV)

If your host doesn't run systemd (Alpine, Devuan, Gentoo, Artix, Void, an older SysV box, a container base image…), everything through **section 4 still applies** — install packages, create the `breeze` user, make the venv, pair your units. Only **section 5 changes**: instead of a `.service` unit you register the process with your init/supervisor.

Whatever you use, the invariants are the same:

- **Command:** `/opt/breeze-core/venv/bin/uvicorn meow_ac.app:app --host <LAN-IP> --port 8420` (bind `127.0.0.1` if a reverse proxy fronts it).
- **User:** run as the unprivileged `breeze` account, never root.
- **Environment:** export `AC_CONFIG` (and, if you split them, `AC_DEVICES`/`AC_PROGRAMS`), pointing at a directory the `breeze` user owns.
- **Working directory:** the repo root (`/opt/breeze-core`) so the package imports and `static/` resolves.
- **Restart:** let the supervisor respawn on exit.

> ⚠️ **You do not get the section-5 kernel sandbox** (egress lockdown, `ProtectSystem`, syscall filter). That protection is systemd-specific. Recover the important parts — outbound-egress lockdown, filesystem confinement, privilege drop — with your firewall and OS features as described in **[HARDENING.md §7 “Hardening without systemd”](../HARDENING.md#7-hardening-without-systemd)**. For an internet-facing box, the strongest non-systemd containment is a **container** (see [DOCKER.md](DOCKER.md), `read_only: true`) or a **FreeBSD jail**.

Ready-to-copy templates for each supervisor live in [`deploy/init/`](../deploy/init/). Pick one:

### OpenRC (Alpine, Gentoo, Artix)
Create the user, then install the service script (from [`deploy/init/openrc-breeze-core`](../deploy/init/openrc-breeze-core)):
```sh
# Alpine uses adduser/addgroup; Gentoo/Artix have useradd like the common steps
addgroup -S breeze 2>/dev/null; adduser -S -D -H -G breeze -s /sbin/nologin breeze
install -m 0755 deploy/init/openrc-breeze-core /etc/init.d/breeze-core
rc-update add breeze-core default
rc-service breeze-core start
rc-service breeze-core status
```
The script (an `openrc-run` service using `supervise-daemon`, which restarts crashes):
```sh
#!/sbin/openrc-run
name="breeze-core"
description="Breeze Core - self-hosted Midea AC control"
: ${BREEZE_HOME:=/opt/breeze-core}
: ${BREEZE_HOST:=192.168.1.10}
command="${BREEZE_HOME}/venv/bin/uvicorn"
command_args="meow_ac.app:app --host ${BREEZE_HOST} --port 8420"
command_user="breeze:breeze"
command_background=false
supervisor="supervise-daemon"
directory="${BREEZE_HOME}"
export AC_CONFIG=/etc/breeze-core/config.json
export AC_DEVICES=/etc/breeze-core/devices.json
export AC_PROGRAMS=/etc/breeze-core/programs.json
depend() { need net; after firewall; }
```

### runit (Void, Artix-runit)
```sh
mkdir -p /etc/sv/breeze-core
install -m 0755 deploy/init/runit-run /etc/sv/breeze-core/run
ln -s /etc/sv/breeze-core /var/service/     # or /etc/runit/runsvdir/default/
sv status breeze-core
```
`/etc/sv/breeze-core/run` (runit expects the process to stay in the **foreground** — uvicorn already does; `chpst` drops privileges and sets env):
```sh
#!/bin/sh
export AC_CONFIG=/etc/breeze-core/config.json
export AC_DEVICES=/etc/breeze-core/devices.json
export AC_PROGRAMS=/etc/breeze-core/programs.json
cd /opt/breeze-core || exit 1
exec chpst -u breeze:breeze \
  ./venv/bin/uvicorn meow_ac.app:app --host 192.168.1.10 --port 8420 2>&1
```
(Log with a `log/run` service piping to `svlogd`, or let your logger capture stdout.)

### s6 / s6-rc
Same shape as runit — a `run` script that stays in the foreground. Use `s6-setuidgid breeze` in place of `chpst -u`:
```sh
#!/bin/sh
cd /opt/breeze-core || exit 1
export AC_CONFIG=/etc/breeze-core/config.json
exec s6-setuidgid breeze ./venv/bin/uvicorn meow_ac.app:app --host 192.168.1.10 --port 8420
```

### supervisord (any OS, incl. containers)
Add to `/etc/supervisor/conf.d/breeze-core.conf` (template: [`deploy/init/supervisor-breeze-core.conf`](../deploy/init/supervisor-breeze-core.conf)):
```ini
[program:breeze-core]
command=/opt/breeze-core/venv/bin/uvicorn meow_ac.app:app --host 192.168.1.10 --port 8420
directory=/opt/breeze-core
user=breeze
environment=AC_CONFIG="/etc/breeze-core/config.json",AC_DEVICES="/etc/breeze-core/devices.json",AC_PROGRAMS="/etc/breeze-core/programs.json"
autostart=true
autorestart=true
stopsignal=INT
stdout_logfile=/var/log/breeze-core.log
redirect_stderr=true
```
```sh
supervisorctl reread && supervisorctl update && supervisorctl status breeze-core
```

### SysV init (legacy)
On a true SysV box, wrap the command with `start-stop-daemon` (Debian-family) or `daemon`/`nohup` + a PID file in `/etc/init.d/breeze-core`, running as `--chuid breeze`, then `update-rc.d breeze-core defaults` (or `chkconfig --add`). A ready script is at [`deploy/init/sysv-breeze-core`](../deploy/init/sysv-breeze-core). Prefer OpenRC/runit/supervisord if you have the choice — they handle respawn and logging for you.

**Verify (any init):** `curl -s -o /dev/null -w '%{http_code}\n' -H 'X-API-Key: WRONG' http://192.168.1.10:8420/api/units` → `401`. Then open the firewall (§6) and — because you have no systemd sandbox — read [HARDENING.md §7](../HARDENING.md#7-hardening-without-systemd).

---

## Non-glibc (musl libc) systems

*(Alpine Linux, Void-musl, OpenWrt, other musl distros, and musl-based containers.)*

Breeze Core is pure Python, but three dependencies ship **compiled** extensions — `pydantic-core` (Rust), `cryptography` (Rust/OpenSSL), and `aiohttp` (C). pip installs these as prebuilt **wheels**, and the default wheels are **manylinux** (glibc-linked). On a musl system those either refuse to install or fail at import with `Error loading shared library ... : No such file or directory`.

There are two clean ways to handle it:

### Option A — musllinux wheels (usually automatic)
Modern releases of all three deps publish **`musllinux`** wheels, which pip ≥ 21.3 selects automatically on a musl host. This is the happy path and needs **no compiler**:
```sh
apk add python3 py3-pip git            # Alpine
python3 -m venv venv
./venv/bin/pip install --upgrade pip   # make sure pip is recent enough to see musllinux wheels
./venv/bin/pip install -r requirements.txt
# sanity check the native bits actually load:
./venv/bin/python -c "import pydantic_core, cryptography, aiohttp; print('musl wheels OK')"
```
If that import line prints `OK`, you're done — continue with pairing (§4) and your init (above).

### Option B — build from source (fallback)
If pip can't find a musllinux wheel for your arch (older releases, uncommon architectures, or you pin an old version), pip will try to **compile**, which needs a toolchain — including **Rust** for `pydantic-core` and `cryptography`:
```sh
# Alpine build dependencies:
apk add build-base python3-dev libffi-dev openssl-dev cargo rust
# then the normal install; pip now compiles what it can't download:
./venv/bin/pip install -r requirements.txt
```
Building `cryptography`/`pydantic-core` from source is slow (minutes) and pulls a lot of `-dev` packages. On a **container image** you'd do this in a builder stage and copy only the finished venv out — the same multi-stage pattern the shipped [Dockerfile](../Dockerfile) uses (that one is glibc/UBI 9; a musl build would swap the base to `python:3.12-alpine` and add the `apk` build deps above in the builder stage).

### Option C — distro packages
Alpine also packages some of these: `apk add py3-cryptography py3-aiohttp` gives you musl-native builds from the distro, and you can create the venv with `--system-site-packages` so pip only needs to fetch the rest. Handy on tiny/slow devices where compiling Rust is painful.

> **Note:** the diagnostic/approval CLIs need `zsh`, `curl`, `jq` (`apk add zsh curl jq`) — same as any distro. And musl gives you **no systemd** either, so you'll use one of the inits above plus [HARDENING.md §7](../HARDENING.md#7-hardening-without-systemd).

---

## FreeBSD and other BSDs

```sh
sudo pkg install python311 py311-pip git         # optional CLIs: curl jq zsh
sudo pw useradd breeze -d /nonexistent -s /usr/sbin/nologin -c "Breeze Core"
# then venv + pair + config as in sections 3–4, e.g. under
#   /usr/local/breeze-core            (code + venv)
#   /usr/local/etc/breeze-core        (config.json etc., chown breeze)
```
Supervise it with **rc.d** — `/usr/local/etc/rc.d/breeze_core` (template: [`deploy/init/freebsd-rc-breeze_core`](../deploy/init/freebsd-rc-breeze_core)):
```sh
#!/bin/sh
# PROVIDE: breeze_core
# REQUIRE: NETWORKING
. /etc/rc.subr
name=breeze_core; rcvar=breeze_core_enable
: ${breeze_core_enable:=NO}
: ${breeze_core_host:=192.168.1.10}
command=/usr/sbin/daemon
procname=/usr/local/breeze-core/venv/bin/python
command_args="-f -u breeze -o /var/log/breeze_core.log \
  -P /var/run/breeze_core.pid \
  /usr/local/breeze-core/venv/bin/uvicorn meow_ac.app:app --host ${breeze_core_host} --port 8420"
breeze_core_env="AC_CONFIG=/usr/local/etc/breeze-core/config.json AC_DEVICES=/usr/local/etc/breeze-core/devices.json AC_PROGRAMS=/usr/local/etc/breeze-core/programs.json"
load_rc_config $name; run_rc_command "$1"
```
```sh
sudo sysrc breeze_core_enable=YES && sudo service breeze_core start
```
Firewall with **pf** (`pass in on $lan proto tcp to port 8420` and a matching egress `block`). **Strongest isolation:** run the whole thing in a thin **jail** — that gives you the filesystem/network confinement systemd provides on Linux. Other BSDs: NetBSD/OpenBSD use their own `rc.d`/`rcctl`; the command and env vars are identical.

## macOS

Home/testing use (macOS has no systemd sandbox; keep it LAN-only):
```sh
brew install python git
# venv + pair + config as in sections 3–4; put state somewhere writable, e.g.
#   AC_CONFIG="$HOME/Library/Application Support/breeze-core/config.json"
```
Keep it running with **launchd** — `~/Library/LaunchAgents/com.breeze.core.plist` (template: [`deploy/init/com.breeze.core.plist`](../deploy/init/com.breeze.core.plist)):
```xml
<plist version="1.0"><dict>
  <key>Label</key><string>com.breeze.core</string>
  <key>ProgramArguments</key><array>
    <string>/opt/breeze-core/venv/bin/uvicorn</string><string>meow_ac.app:app</string>
    <string>--host</string><string>192.168.1.10</string><string>--port</string><string>8420</string>
  </array>
  <key>WorkingDirectory</key><string>/opt/breeze-core</string>
  <key>EnvironmentVariables</key><dict>
    <key>AC_CONFIG</key><string>/opt/breeze-core/config.json</string>
  </dict>
  <key>RunAtLoad</key><true/><key>KeepAlive</key><true/>
</dict></plist>
```
```sh
launchctl load ~/Library/LaunchAgents/com.breeze.core.plist
```
Firewall with the built-in Application Firewall or `pf`. For an always-on internet-facing deployment, prefer a Linux/systemd box or a container.

## Windows

Windows is a **first-class** target: a guided **NSIS installer** sets Breeze
Core up as a hardened Windows **service** (bundled NSSM, low-privilege
`LOCAL SERVICE`, LAN-locked firewall), with an optional guided **Caddy** reverse
proxy (auto-HTTPS) and a **fail2ban-style** IP banner. The full guide is
**[docs/WINDOWS.md](WINDOWS.md)** — start there.

Quick testing run (no service), in PowerShell from the repo root:
```powershell
$env:AC_CONFIG="C:\ProgramData\breeze-core\config.json"
.\venv\Scripts\python.exe setup_device.py                                    # pair
.\venv\Scripts\uvicorn.exe meow_ac.app:app --host 192.168.1.10 --port 8420
```
For anything persistent, use the installer or the scripts in
[`deploy/windows/`](../deploy/windows/) — see [WINDOWS.md](WINDOWS.md).

### WSL (Windows Subsystem for Linux)
Follow the [Debian/Ubuntu path](#1b-debian--compatibles) *inside* WSL2, with two caveats:
- **Enable systemd** so the section-5 service works — add to `/etc/wsl.conf`, then `wsl --shutdown` and reopen:
  ```ini
  [boot]
  systemd=true
  ```
- **Networking:** WSL2 is NAT'd, so LAN units/clients can't reach it by default. Easiest fix (Windows 11): mirrored networking — add `networkingMode=mirrored` under `[wsl2]` in `%UserProfile%\.wslconfig`. Otherwise port-proxy from Windows: `netsh interface portproxy add v4tov4 listenport=8420 connectaddress=<wsl-ip> connectport=8420`.

---

Next: expose it safely from outside your LAN → **[REVERSE-PROXY.md](REVERSE-PROXY.md)**, and review **[HARDENING.md](../HARDENING.md)** — especially **[§7 Hardening without systemd](../HARDENING.md#7-hardening-without-systemd)** if you're not on a systemd host.
