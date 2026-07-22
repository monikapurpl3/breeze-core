[← Breeze Core](../README.md)

# Installing from packages (no Python needed)

Every release ships **self-contained builds** — the server, its web UI, and a
private Python runtime in one bundle, wrapped as native packages. Nothing to
compile, no Python to install, no venv.

**Contents:**
[Package repository](#the-package-repository-recommended) ·
[Manual download](#manual-download-github-releases) ·
[Package details](#package-details) ·
[NixOS / Nix](#nixos--nix) ·
[For packagers](#source-recipes-for-packagers) ·
[OpenWrt](#openwrt) ·
[BSDs](#freebsd-openbsd-netbsd)

## The package repository (recommended)

Add the signed repo at **https://bolero.salataputarica.hr.eu.org** once, and
installs *and updates* flow through your normal package manager
(`apt upgrade`, `dnf upgrade`, `pacman -Syu`, `apk upgrade`). Copy-paste
setup for each family is on the [repo landing
page](https://bolero.salataputarica.hr.eu.org); the same commands are
summarized in the README's Get started. Integrity model: the repo is built
and signed offline (apt `InRelease`, signed rpms + `repo_gpgcheck`, pacman
`SigLevel = Required`, RSA-signed `APKINDEX`) — the web host serves static
files only and holds no keys.

## Manual download (GitHub releases)

Prefer a one-off file? Grab it from the
[latest release](https://github.com/monikapurpl3/breeze-core/releases).

After any of the installs below, the same three steps finish the job:

```bash
sudo breeze-core pair                        # 1. find your ACs, write the config
sudoedit /etc/breeze-core/breeze-core.env    # 2. set BREEZE_HOST=<this machine's LAN IP>
sudo systemctl enable --now breeze-core      # 3. start it (OpenRC/runit: see your section)
```

Then open `http://<BREEZE_HOST>:8420`, enter the API key (it's in
`/etc/breeze-core/config.json`), and pair. The service runs as the
unprivileged `breeze` user with the same systemd sandbox the source install
documents. Uninstalling keeps `/etc/breeze-core` (your config + device
tokens) unless you delete it yourself.

| You run | Grab | Install with |
|---|---|---|
| Debian, Ubuntu, Mint, Pop!_OS, Raspberry Pi OS, Armbian, Devuan | `breeze-core_<v>_amd64.deb` (or `_arm64`) | `sudo apt install ./breeze-core_<v>_amd64.deb` |
| Fedora, RHEL, AlmaLinux, Rocky, openSUSE Leap/Tumbleweed, SLE | `breeze-core-<v>-1.x86_64.rpm` (or `.aarch64`) | `sudo dnf install ./breeze-core-<v>-1.x86_64.rpm` / `sudo zypper in --allow-unsigned-rpm ./…` |
| Arch, Manjaro, Artix | `breeze-core-<v>-1-x86_64.pkg.tar.zst` | `sudo pacman -U breeze-core-<v>-1-x86_64.pkg.tar.zst` |
| Alpine | `breeze-core_<v>_x86_64.apk` (or `_aarch64`) | `sudo apk add --allow-untrusted ./breeze-core_<v>_x86_64.apk` |
| OpenWrt (x86_64 / aarch64, ~65 MB free) | signed **opkg feed** on the repo | see [OpenWrt](#openwrt) below |
| Void, Gentoo, Slackware, anything else | `breeze-core-<v>-linux-<glibc\|musl>-<amd64\|arm64>.tar.gz` | unpack, then `sudo ./install.sh` |
| Windows | `Breeze-Core-Setup.exe` | double-click — see [WINDOWS.md](WINDOWS.md) |
| Docker / Podman | `ghcr.io/monikapurpl3/breeze-core` | see [DOCKER.md](DOCKER.md) |
| NixOS / Nix | the repo's **flake** | see below |

**Which tarball?** `glibc` for almost every distro; `musl` only for Alpine and
Void-musl. `amd64` = regular PCs, `arm64` = Raspberry Pi 3+/ARM boards. The
generic `install.sh` detects systemd, OpenRC, or runit and installs the
matching service; on anything else it prints what to wire up (templates in
[`deploy/init/`](../deploy/init/)).

Every one of these is exercised in CI on real distro userlands
(Debian/Ubuntu/Mint/Devuan/Leap/Tumbleweed/SLE/Alma/Arch/Manjaro/Artix/
Alpine/Void/Gentoo + an arm64 pass) before a release goes out.

## Package details

- **Program:** `/usr/lib/breeze-core/` (self-contained bundle), `breeze-core`
  on `PATH`. Subcommands: `serve`, `pair`, `version`, plus the admin/diagnostic
  tools: `diag` (full health/security battery), `approve <CODE>`, `devices`,
  `revoke <token_id>` — see [TROUBLESHOOTING.md](TROUBLESHOOTING.md#the-diagnostic--approval-clis).
- **State:** `/etc/breeze-core/` — `config.json` (mode 640), `devices.json`,
  `programs.json`; owned by the `breeze` service user; dir mode 750.
- **Service config:** `/etc/breeze-core/breeze-core.env` (`BREEZE_HOST`,
  `BREEZE_PORT`, `BREEZE_OPTS=--behind-proxy` behind a reverse proxy). Marked
  as a config file — package upgrades never overwrite it.
- **Service:** systemd unit (deb/rpm/pacman) or OpenRC init (apk), hardened
  per [HARDENING.md](../HARDENING.md); runit template ships in the tarball.
- OpenRC start: `sudo rc-update add breeze-core default && sudo rc-service breeze-core start`.

## NixOS / Nix

The repo is a flake. Try it without installing:

```bash
nix run github:monikapurpl3/breeze-core -- version
```

On NixOS, use the module — it wires the service, user, sandbox, and state dir:

```nix
{
  inputs.breeze-core.url = "github:monikapurpl3/breeze-core";
  # ...
  imports = [ breeze-core.nixosModules.breeze-core ];
  services.breeze-core = {
    enable = true;
    host = "192.168.1.10";     # this machine's LAN IP
    openFirewall = true;
  };
}
```

Pair once with `sudo breeze-core pair` (or set `AC_CONFIG` and run it as the
service user), then the module's systemd unit picks the config up.

## Source recipes (for packagers)

Prefer building from source, or maintaining a distro repo? See
[`packaging/source/`](../packaging/source/): an AUR-style `PKGBUILD`
(source venv build), a Gentoo `-bin` ebuild + `acct-user`/`acct-group`, and a
Void `xbps-src` template. The classic source install (venv + systemd unit)
remains fully documented in [INSTALL.md](INSTALL.md).

## OpenWrt

Real `.ipk` packages from a **usign-signed opkg feed** — the same signer
OpenWrt itself uses, so `opkg update` verifies the feed. Covers **x86_64**
and the common **aarch64** targets (`aarch64_generic`, `cortex-a53`,
`cortex-a72`); the app needs **~65 MB of storage**, so this is for x86
boxes, RPi/NAS-class devices, or routers with
[extroot](https://openwrt.org/docs/guide-user/additional-software/extroot_configuration):

```sh
wget -q -O /tmp/breeze.pub https://bolero.salataputarica.hr.eu.org/openwrt/breeze-core-usign.pub
cp /tmp/breeze.pub "/etc/opkg/keys/$(usign -F -p /tmp/breeze.pub)"
echo "src/gz breeze_core https://bolero.salataputarica.hr.eu.org/openwrt/$(. /etc/openwrt_release; echo $DISTRIB_ARCH)" \
  >> /etc/opkg/customfeeds.conf
opkg update && opkg install breeze-core
```

Then `breeze-core pair`, set `BREEZE_HOST` in
`/etc/breeze-core/breeze-core.env`, and `/etc/init.d/breeze-core start` — it
runs as the unprivileged `breeze` user under **procd** with respawn. Works on
OpenWrt **23.05 and newer** (the musl bundles are built against musl 1.2.4
for exactly this reason). Other router architectures (mips, arm32) can't fit
or run the self-contained bundle — for those, nothing beats a small x86/ARM64
box next to the router.

## FreeBSD, OpenBSD, NetBSD

The Linux self-contained bundles are Linux ELF binaries — they can't run on a
BSD kernel (and a container can't help, since it shares the host's Linux
kernel). So BSD installs **from source** into a private virtualenv: the same
`meow_ac.app:app`, built on the host. One command from a checkout (or the
source tarball) does the lot — service user, venv + deps, a `breeze-core`
wrapper, the rc.d service, and the env file:

```sh
# FreeBSD:  pkg install -y python311 py311-pip rust
# OpenBSD:  pkg_add python%3.11 rust
# NetBSD:   pkgin -y install python311 py311-pip rust
#   (rust builds pydantic-core; a C compiler ships in base)

doas sh packaging/bsd/install.sh     # OpenBSD (or `sudo`/`su` on FreeBSD/NetBSD)
```

Then `breeze-core pair`, set `BREEZE_HOST` in the env file, and enable the
service — `sysrc breeze_core_enable=YES && service breeze_core start`
(FreeBSD), `rcctl enable breeze_core && rcctl start breeze_core` (OpenBSD), or
`breeze_core=YES` in `/etc/rc.conf` + `service breeze_core start` (NetBSD).

All three are **exercised on real FreeBSD / OpenBSD / NetBSD VMs in CI**
(`.github/workflows/bsd.yml`, via `vmactions`): install → `breeze-core
version` → serve → `GET /api/health`, with FreeBSD also starting the rc
service and building a **native `.pkg`** (`packaging/bsd/mkpkg-freebsd.sh`,
uploaded as a CI artifact). The full CLI (`serve`/`pair`/`diag`/`approve`/…)
and every API feature work exactly as on Linux.

**FreeBSD is verified on real hardware** (FreeBSD 15.1): the installer +
rc.d service run, and `mkpkg-freebsd.sh` builds a **native `.pkg`** that
clean-installs via `pkg add` and serves — attached to releases and, once
v3.0.0 is stable, served from a signed `pkg` repo. **NetBSD** needs a release
whose pkgsrc binary repo actually carries `python312` + `rust` (a stable
**10.0** does; a fresh **11.0-RC** repo may not yet). Ports/pkgsrc submissions
are welcome — `packaging/bsd/` has the rc scripts and installer to build on.
