# Running Breeze Core in Docker

A compact, non-root container built on Red Hat **UBI 9 minimal** (free & redistributable, glibc, security-patched). Image: `ghcr.io/monikapurpl3/breeze-core`.

## Why UBI 9 (and not Debian / Alpine / "distroless")?

The base image was a deliberate choice; the short version is **security patching + stability + a clean license, with glibc**:

- **Enterprise-grade, no-cost security maintenance.** UBI is the same RPM stream as RHEL, patched by Red Hat's product-security team with published CVE errata and a long support lifecycle (RHEL 9 into the 2030s). You inherit that patch cadence for the OS layer without a subscription — UBI is [freely redistributable](https://www.redhat.com/en/blog/introducing-red-hat-universal-base-image). Debian's security is solid and community-run; the difference is the formal errata/lifecycle guarantees, which matter for a thing you expose to the internet.
- **Stability.** A RHEL-pinned userland barely moves within a major version — the same reason it's a boring, dependable server base. Fewer surprise ABI/toolchain shifts between rebuilds than a fast-moving base.
- **glibc, so wheels "just work".** Python's prebuilt **manylinux** wheels (pydantic-core, cryptography, aiohttp…) target glibc. UBI is glibc, so the default image installs binary wheels with no compiler. That's also why the **Alpine** variant is opt-in only — musl needs musllinux wheels or a from-source build (see the Alpine note below).
- **Clean licensing.** UBI's terms explicitly allow redistribution of derived images, so publishing to a public registry is unambiguous.
- **Rootless / OpenShift-friendly.** The image runs as a non-root UID in group 0 with a group-writable state dir — the UBI convention for arbitrary-UID platforms.

Trade-offs, honestly: UBI minimal (~15 MB larger than Alpine) isn't the tiniest option, and it's a Red Hat ecosystem base rather than a community one. If you specifically want musl/smallest, build the [Alpine variant](#image-variants); if you want a different distro entirely, the app is plain Python + `uvicorn meow_ac.app:app` and will run on any base you like.

## Get the image

```bash
# pull the published multi-arch image (amd64 / arm64):
docker pull ghcr.io/monikapurpl3/breeze-core:latest
# …or build it yourself:
docker build -t breeze-core .
```

### Image variants

| Tag | Base | For |
|---|---|---|
| `:latest`, `:vX.Y.Z` | UBI 9 (glibc), **amd64 + arm64** | Everyone — the default. |
| `:vX.Y.Z-x86-64-v2` | UBI 9 (glibc), amd64 | Broadly-compatible microarch build (SSE4.2/POPCNT). |
| `:vX.Y.Z-x86-64-v3` | UBI 9 (glibc), amd64 | Modern-CPU microarch build (**AVX2/BMI2/FMA**). |

> **glibc vs musl.** The published image is glibc (UBI 9), which covers virtually all hosts. If you specifically need a **musl / Alpine** image (non-glibc base, smallest size), build the provided variant: `docker build -f Dockerfile.alpine -t breeze-core:alpine .`. Its builder stage carries a Rust/C toolchain so it compiles the native wheels when no musllinux wheel exists — see [INSTALL.md → Non-glibc (musl libc) systems](INSTALL.md#non-glibc-musl-libc-systems).

> **x86-64 microarchitecture variants (`-x86-64-v2` / `-x86-64-v3`).** These compile **every** dependency from source (`pip --no-binary :all:`) with `-march`/`target-cpu` set, so the native extensions (pydantic-core, cryptography, aiohttp, …) use newer instruction sets. `v2` runs on essentially any x86-64 CPU; **`v3` requires AVX2** (Haswell/Excavator or newer) and will `SIGILL` on older CPUs — match the level to your host (`cat /sys/devices/cpu/caps/…` or just try). The workload is LAN-I/O-bound, so gains are modest; use these only if you want them. Build locally with `docker build -f Dockerfile.march --build-arg MARCH=x86-64-v3 -t breeze-core:v3 .`. **arm64 users:** stick with `:latest`.

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
