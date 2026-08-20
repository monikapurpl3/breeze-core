[← Breeze Core](../README.md)

# Running Breeze Core in a container

Five images, rebuilt from scratch for 3.1.0, each named for exactly what it is.
`ghcr.io/monikapurpl3/breeze-core`.

| Tag | Base | libc | Arch | For |
|---|---|---|---|---|
| `latest` = `alpine-edge` | Alpine Edge | musl | **amd64 + arm64** | The default. Small, rolling, updates its own base packages. |
| `alpine-edge-x86_64` | Alpine Edge | musl | amd64 | The same, pinned to one architecture. |
| `alpine-edge-aarch64` | Alpine Edge | musl | arm64 | Pi 4/5, ARM servers. |
| `alpine-edge-nginx-x86_64` | Alpine Edge | musl | amd64 | **HTTPS out of the box** — nginx bundled, certificate generated on first start. |
| `ubi9-x86-64-v2` | Red Hat UBI 9 | glibc | amd64 | glibc on a vendor-patched base. Runs on any x86-64 from ~2009. |
| `ubi9-x86-64-v3` | Red Hat UBI 9 | glibc | amd64 | The same compiled for AVX2-era CPUs (Haswell / Excavator or newer). |

Every image also gets a pinnable `…-<version>` tag (`ubi9-x86-64-v2-3.1.0`),
published for release tags only. `latest` and `alpine-edge` are the same
manifest list, and the only tags that resolve on both architectures — psABI
levels are an x86 concept, so the UBI images are x86-64 by construction.

**Which one:** not sure → `latest`. Want HTTPS without configuring a proxy →
`alpine-edge-nginx-x86_64`. Prefer glibc and a vendor-patched base →
`ubi9-x86-64-v2`. Full detail, and how the images are built and checked:
[containers/README.md](../containers/README.md).

## Start it

```bash
docker run -d --name breeze-core --restart unless-stopped --network host \
  -v breeze-config:/etc/breeze-core \
  -e TZ=Europe/Zagreb \
  ghcr.io/monikapurpl3/breeze-core:latest

docker logs breeze-core          # prints the generated API key, once
docker exec -it breeze-core breeze-setup
```

There is no pairing step to do first. On its very first start the container
writes a config with a fresh API key (mode 640), prints it, and comes up
serving — so the panel is reachable immediately and nothing crash-loops on a
file that does not exist yet.

`breeze-setup` then walks the whole of first-time setup: the API key, finding and
pairing the air conditioners, admitting the first phone or browser, and — in the
nginx image — the certificate and server name. Every step can be skipped, so it
is also the "what was that command again" script later on.

Or with compose, which has a service per image family:

```bash
docker compose up -d                    # latest (Alpine Edge, multi-arch)
docker compose --profile https up -d    # the nginx image, HTTPS on 8443
docker compose --profile ubi up -d      # UBI 9 / glibc
```

## `TZ` is not cosmetic

Schedules and curves run on the server's local clock. Set `TZ` or they fire on
UTC — an hour or two out, silently, all year.

All five images carry the timezone database because of this. The previous images
did not: `ubi-minimal` has no `tzdata`, so `TZ=Europe/Zagreb` resolved to UTC and
`time.tzname` came back as the nonsensical `('Europe', 'Europe')`. Anything
scheduled ran on the wrong clock with nothing in any log to say so.

## The networking question (read this)

Breeze Core talks to air conditioners on your LAN:

- **Discovery** is a UDP **broadcast**, which does not leave Docker's default
  bridge network. On the bridge the symptom is simply "no units found", which
  looks like broken hardware.
- **Control** — reaching a unit by address — works from a bridge network fine.
- **LAN-only pairing approval** needs to see real client addresses.

So: **host networking** for a home server. `docker-compose.yml` uses it. If you
must use bridge networking, pair by address (`breeze-core pair --ip 192.168.1.50`)
and publish the port only to your proxy (`-p 127.0.0.1:8420:8420`).

## HTTPS, two ways

**Bring your own proxy** (any image): keep the app on `127.0.0.1`, put nginx or
Caddy in front, and set `AC_BEHIND_PROXY=1` plus `AC_TRUSTED_HOSTS`. See
[REVERSE-PROXY.md](REVERSE-PROXY.md) and [HARDENING.md](../HARDENING.md). The
wizard at [`deploy/reverse-proxy-wizard.sh`](../deploy/reverse-proxy-wizard.sh)
writes the config for you.

**Or use the bundled-nginx image**, which is the same thing pre-wired:

```bash
docker run -d --name breeze-core --restart unless-stopped --network host \
  -v breeze-config:/etc/breeze-core \
  -e TZ=Europe/Zagreb \
  -e BREEZE_SERVER_NAME=breeze.lan \
  -e BREEZE_PUBLIC_HTTPS_PORT=8443 \
  ghcr.io/monikapurpl3/breeze-core:alpine-edge-nginx-x86_64
```

HTTPS on 8443, plain HTTP on 8080 redirecting to it, a self-signed certificate
generated into the state volume on first start (the log prints its SHA-256 — worth
comparing the first time a browser asks). Drop your own `fullchain.pem` and
`privkey.pem` into `/etc/breeze-core/tls/` to use a real one instead; nothing
overwrites an existing pair.

Two details it gets right that are easy to get wrong by hand: `X-Forwarded-For`
is set to `$remote_addr` rather than appended, so a client cannot forge its way
into looking LAN-local; and `proxy_buffering` is off with a long read timeout, so
the live view's SSE stream actually streams instead of appearing frozen.

`BREEZE_PUBLIC_HTTPS_PORT` must be the port you actually publish — it is what the
plain-HTTP listener redirects to, and the default `https://$host` would only be
right if you mapped 8443 onto 443.

## Alpine Edge keeps itself current

Edge is a rolling branch, so an image of it starts going stale immediately.
`BREEZE_EDGE_UPDATE` decides what the container does about that: `start` (the
default) upgrades base packages once before the server starts; `daily` also checks
every 24 hours and, if packages changed, **stops the container** so your restart
policy brings it back on the new libraries; `off` never touches apk.

Python is pinned to its minor series (`python3~3.14`), and that pin is what makes
this safe: the venv holds extensions compiled for one interpreter minor, there is
no compiler in the runtime image, and a jump to 3.15 would leave nothing
importable. Patch releases, CPython security fixes included, still arrive.

The self-update needs root, so the Alpine images start as root, run apk, fix the
ownership of a fresh volume, then hand the server to uid 1001 via `su-exec` for
the rest of its life. `--user 1001` skips all of that; the updater then reports
itself skipped rather than failing quietly. The UBI images run as 1001 throughout
and have no self-update.

## Notes

- **Non-root:** the server always runs as uid 1001. On UBI that is uid 1001 in
  group 0 with a group-writable state dir, the convention for OpenShift's
  arbitrary-UID policy. A **bind-mounted** state dir must be writable by that uid
  (`chown 1001 ./state`); a **named volume** is fixed up automatically on the
  Alpine images and initialised correctly by Docker on the UBI ones.
- **The v3 image refuses to start** on a CPU without AVX2, naming the missing
  flags and pointing at the v2 image — rather than dying of `SIGILL` from inside
  some native wheel at an arbitrary later moment.
- **Secrets:** `.dockerignore` keeps `config.json` / `devices.json` /
  `programs.json` out of every image; they exist only in the volume.
- **Read-only rootfs:** supported on the non-nginx images — add `read_only: true`
  and `tmpfs: /tmp`; only `/etc/breeze-core` needs to be writable. The nginx image
  needs `/tmp` writable too, which the tmpfs covers.
- **Updates:** `docker compose pull && docker compose up -d`. State persists.
- **Which image am I running?** The banner on every start says so, and
  `docker exec <c> cat /etc/breeze-image.env` or
  `docker inspect --format '{{index .Config.Labels "org.opencontainers.image.title"}}' <c>`
  answers the same question from outside.

## Why these bases

**Alpine Edge as the default.** It is the only one of the five that covers both
architectures, it is the smallest, and — with the interpreter pin above — it can
keep its own base current, which suits an appliance nobody logs into. Edge rather
than a numbered release because the point of this image is current everything;
if that sounds wrong for your box, the UBI images are the conservative option.

**UBI 9 for glibc.** Same RPM stream as RHEL, patched by Red Hat's product
security team with published errata and a lifecycle into the 2030s, and
[freely redistributable](https://www.redhat.com/en/blog/introducing-red-hat-universal-base-image),
so publishing derived images is unambiguous. glibc also means PyPI's manylinux
wheels apply — though these images compile their dependencies from source anyway,
to target the psABI level in the tag.

**Why compile from source for v2/v3 at all.** PyPI's wheels are built for the
*baseline* x86-64 — no SSE4.2, no AVX2 — because they must run anywhere. RHEL 9
itself already requires x86-64-v2, so its Python sits a level above the wheels it
would install. These images close that gap. The honest caveat: this workload is
LAN-round-trip bound, so expect the gain to be small. The v3 image exists because
the hardware is there, not because a profile demanded it.
