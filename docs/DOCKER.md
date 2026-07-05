# Running Breeze Core in Docker

A compact, non-root container built on Red Hat **UBI 9 minimal** (free & redistributable, glibc, security-patched). Image: `ghcr.io/monikapurpl3/breeze-core`.

## Get the image

```bash
# pull the published multi-arch image (amd64 / arm64):
docker pull ghcr.io/monikapurpl3/breeze-core:latest
# …or build it yourself:
docker build -t breeze-core .
```

> **glibc vs musl.** The published image is glibc (UBI 9), which covers virtually all hosts. If you specifically need a **musl / Alpine** image (non-glibc base, smallest size), build the provided variant: `docker build -f Dockerfile.alpine -t breeze-core:alpine .`. Its builder stage carries a Rust/C toolchain so it compiles the native wheels when no musllinux wheel exists — see [INSTALL.md → Non-glibc (musl libc) systems](INSTALL.md#non-glibc-musl-libc-systems).

## The networking question (read this)

Breeze Core talks to Midea units on your LAN:

- **Discovery** (`setup_device.py`, no `--ip`) uses a UDP **broadcast**, which only works with **host networking**.
- **Control** (reaching a unit's IP) works from a normal bridge network too.

For a home server the simplest, most reliable setup is **host networking** — the container shares the host's network, discovers units, reaches them, and sees real client IPs (so LAN-only pairing approval works without extra config). The provided `docker-compose.yml` uses it.

If you must use bridge networking, pair with explicit IPs (`setup_device.py --ip …`) and expose the port only to your proxy (`-p 127.0.0.1:8420:8420`).

## 1. Pair your units (one-time)

Config/state lives in the `/etc/breeze-core` volume. Run the pairing script once, with host networking so discovery works:

```bash
docker run --rm -it --network host \
  -v breeze-config:/etc/breeze-core \
  ghcr.io/monikapurpl3/breeze-core:latest \
  python setup_device.py
```
It writes `config.json` into the volume and prints the API key once — **save it**. (For a single known unit: append `--ip 192.168.1.73`.)

## 2. Run it

```bash
docker compose up -d          # uses docker-compose.yml (host networking + volume)
docker compose logs -f
```
Or without compose:
```bash
docker run -d --name breeze-core --restart unless-stopped --network host \
  -v breeze-config:/etc/breeze-core \
  ghcr.io/monikapurpl3/breeze-core:latest \
  uvicorn meow_ac.app:app --host 127.0.0.1 --port 8420
```
Health: `docker inspect --format '{{.State.Health.Status}}' breeze-core` → `healthy` once the UI answers.

## 3. Expose it (optional)

Keep the container bound to `127.0.0.1` and put a reverse proxy in front — the wizard at [`deploy/reverse-proxy-wizard.sh`](../deploy/reverse-proxy-wizard.sh) generates it. Then set, in compose:
```yaml
environment:
  AC_BEHIND_PROXY: "1"
  AC_TRUSTED_HOSTS: "breeze.example.com,127.0.0.1"
```
See [REVERSE-PROXY.md](REVERSE-PROXY.md) and [HARDENING.md](../HARDENING.md).

## Notes

- **Non-root:** runs as UID 1001 (group 0). A **bind-mounted** state dir must be writable by that UID (`chown 1001:0 ./state`); a **named volume** (as in compose) is initialized with the right ownership automatically.
- **Secrets:** the `.dockerignore` keeps `config.json`/`devices.json`/`programs.json` out of the image; they live only in the volume.
- **Read-only rootfs:** supported — add `read_only: true` and `tmpfs: /tmp` in compose; only `/etc/breeze-core` needs to be writable.
- **Updates:** `docker compose pull && docker compose up -d`. Data persists in the volume.
- **GHCR visibility:** the first publish creates a *private* package. Make it public in the repo's package settings if you want others to pull without auth.
