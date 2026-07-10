# Installing from packages (no Python needed)

Every release ships **self-contained builds** — the server, its web UI, and a
private Python runtime in one bundle, wrapped as native packages. Nothing to
compile, no Python to install, no venv. Grab yours from the
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
  on `PATH`. Subcommands: `serve`, `pair`, `version`.
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

## FreeBSD, NetBSD, OpenWrt

No prebuilt bundles (different kernels / exotic architectures) — the
[source install](INSTALL.md#freebsd-and-other-bsds) works today on the BSDs,
and OpenWrt is documented there too. Native `.pkg` builds via poudriere are
planned.
