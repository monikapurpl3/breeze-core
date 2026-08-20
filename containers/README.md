[← Breeze Core](../README.md)

# The five container images

Rebuilt from scratch for 3.1.0. Each one says what it is — in its tag, in its
OCI labels, in `/etc/breeze-image.env`, and in a banner it prints on every start.
The old scheme had tags like `latest-x86-64-v2` and no way to tell a musl image
from a glibc one without pulling it; this replaces that.

| Tag | Base | libc | Arch | For |
|---|---|---|---|---|
| `ubi9-x86-64-v2` | Red Hat UBI 9 | glibc | amd64 | The conservative x86 choice. Runs on anything from ~2009 on. |
| `ubi9-x86-64-v3` | Red Hat UBI 9 | glibc | amd64 | Same, compiled for AVX2-era CPUs (Haswell / Excavator or newer). |
| `alpine-edge-x86_64` | Alpine Edge | musl | amd64 | Small, rolling, updates its own base packages. |
| `alpine-edge-aarch64` | Alpine Edge | musl | arm64 | The same for a Pi 4/5 or an ARM server. |
| `alpine-edge-nginx-x86_64` | Alpine Edge | musl | amd64 | The above **plus nginx**: HTTPS works on first start, no proxy to set up. |

Each also gets a pinnable `…-<version>` tag (`ubi9-x86-64-v2-3.1.0`), published
only for release tags. `alpine-edge` is a manifest list over the two Alpine
images, and `latest` points at the same list — the only tag that resolves on both
architectures, since a psABI level is an x86 concept and the UBI images are
x86-64 by construction.

## Which one

- **Not sure → `latest`.** Multi-arch, self-updating, small.
- **Want HTTPS without touching nginx → `alpine-edge-nginx-x86_64`.**
- **Prefer glibc and a vendor-patched base → `ubi9-x86-64-v2`.**
- **Know your CPU is Haswell or newer and want the instructions used →
  `ubi9-x86-64-v3`.** It refuses to start on a CPU that cannot run it, rather
  than dying of SIGILL somewhere unhelpful later.

## First run, whichever you picked

The container comes up serving. It writes a config with a fresh API key and
prints it once, so there is nothing to prepare first:

```bash
docker run -d --name breeze-core --network host \
  -v breeze-config:/etc/breeze-core \
  -e TZ=Europe/Zagreb \
  ghcr.io/monikapurpl3/breeze-core:latest

docker logs breeze-core          # the API key is in here
docker exec -it breeze-core breeze-setup
```

`breeze-setup` is the whole first-time setup in one script: the API key, finding
and pairing the air conditioners, admitting the first phone or browser, and — in
the nginx image — the certificate and server name. It is safe to re-run; every
step can be skipped.

Underneath it, the same CLI as everywhere else:

```bash
docker exec -it breeze-core breeze-core pair       # discover + pair units
docker exec -it breeze-core breeze-core approve <CODE>
docker exec    breeze-core breeze-core devices     # what is enrolled
docker exec    breeze-core breeze-core diag --auto # the diagnostic battery
```

## `TZ` is not cosmetic

Schedules and curves run on the server's local clock. Set `TZ` or they fire on
UTC. All five images carry the timezone database for this reason — the previous
images did not, so `TZ=Europe/Zagreb` silently resolved to UTC and every program
ran hours out.

## Alpine Edge keeps itself current

Edge is a rolling branch, so the image is a snapshot that starts going stale the
moment it is published. `BREEZE_EDGE_UPDATE` controls what it does about that:

| Value | Behaviour |
|---|---|
| `start` (default) | `apk upgrade` once at container start, before the server starts. A restart is all it takes to be current. |
| `daily` | As above, plus a check every 24h. If packages actually changed it **stops the container** so the restart policy brings it back on the new libraries — an upgrade alone does nothing for processes that already mapped the old ones. Needs `restart: unless-stopped`. |
| `off` | Never touches packages. |

**Python is pinned to its minor series** (`python3~3.14` in `/etc/apk/world`), and
that pin is what makes a rolling base safe here: the venv holds compiled
extensions named for one interpreter minor (`…cpython-314-…musl.so`), there is no
compiler in the runtime image, and a jump to 3.15 would leave nothing importable.
Patch releases — CPython security fixes included — still arrive. Crossing a minor
is a new image, which is what tags are for.

The self-update needs root, so the Alpine images start as root, run `apk`, fix the
owner of a fresh volume, and then hand the server to uid 1001 through `su-exec`
for the rest of its life. Start them with `--user 1001` to skip that entirely; the
updater then reports itself skipped. The UBI images run as 1001 from the start and
have no self-update.

## Build and check them yourself

```bash
containers/build.sh                  # all five, into the local docker store
containers/build.sh ubi9-v3          # just one
containers/build.sh --push           # publish, plus the manifest lists
containers/test.sh                   # smoke-test whatever is built
containers/test.sh --deep            # also disassemble, to prove -march applied
```

`--deep` is worth a word. It pulls `_pydantic_core…so` out of both UBI images and
disassembles it, and the naive assertion ("the v2 image contains no AVX2") is
false: v2 has ~700 AVX2 instructions. They are not a leaked compiler flag, they
are runtime-dispatched paths inside dependencies like `memchr`, which ask CPUID
before using them — the same object also contains the CPUID checks. What actually
separates the images is the order of magnitude: **~700 in v2 against ~38,000 in
v3**. Had `-march` silently not applied, both would sit at the same
dispatch-only floor.

## Layout

```
containers/
  common/entrypoint       identity banner, CPU guard, first-run config, privilege drop
  common/breeze-setup     the interactive first-time setup (all five images)
  common/breeze-core      CLI wrapper on the vendored interpreter
  ubi9/Dockerfile         images 1 and 2, ARCH_LEVEL=x86-64-v2|v3
  alpine/Dockerfile       images 3 and 4, one file, two platforms
  alpine/edge-update      the self-updater, and why python is pinned
  alpine-nginx/Dockerfile image 5, layered on image 3
  alpine-nginx/nginx.conf TLS, SSE-safe proxying, XFF as $remote_addr
  alpine-nginx/supervise   nginx + app in one container, dying together
  alpine-nginx/breeze-tls-init  self-signed cert + the generated snippets
  build.sh  test.sh       the tag scheme, and the checks
```
