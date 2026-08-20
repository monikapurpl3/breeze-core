# syntax=docker/dockerfile:1
#
# Breeze Core — Alpine Edge, musl, x86_64 or arm64.
#
#   docker build -f containers/alpine/Dockerfile --platform linux/amd64 .
#   docker build -f containers/alpine/Dockerfile --platform linux/arm64 .
#
# Edge, not a numbered Alpine release, on purpose: this is the image for people
# who want current everything, and it can keep itself current — see
# containers/alpine/edge-update, and BREEZE_EDGE_UPDATE below.
#
# THE ONE THING THAT MAKES A ROLLING BASE SAFE HERE: the venv holds compiled
# extensions named for one interpreter minor version
# (_pydantic_core.cpython-314-x86_64-linux-musl.so). If apk moved python3 from
# 3.14 to 3.15 they would all stop importing, and there is no compiler in the
# runtime image to rebuild them. So the build pins python3 to its minor series
# in /etc/apk/world — python3~3.14 — which lets 3.14.x patch releases and
# CPython security fixes in while refusing the minor jump. Crossing a minor is
# an image rebuild; that is what pulling a new tag is for.

########################  builder  ########################
FROM alpine:edge AS builder

# Edge ships Python 3.14, which is ahead of a good few projects' published
# wheels, so assume nothing is prebuilt: rust and a C toolchain are here because
# pydantic-core, uvloop, httptools, watchfiles and pycryptodome may all need
# compiling. This whole stage is thrown away.
RUN apk add --no-cache \
        python3 python3-dev py3-pip \
        build-base cargo rust libffi-dev openssl-dev

WORKDIR /build
COPY requirements.txt .

# A wheelhouse, then an offline install into the venv — same shape as the UBI
# image, for the same reason: what got built is visible and checkable instead of
# being an invisible side effect of pip.
RUN python3 -m venv /opt/breeze/venv \
    && /opt/breeze/venv/bin/pip install -q --no-cache-dir --upgrade pip wheel \
    && /opt/breeze/venv/bin/pip wheel --no-cache-dir -r requirements.txt -w /wheelhouse \
    && ls -1 /wheelhouse

RUN /opt/breeze/venv/bin/pip install -q --no-cache-dir --no-index \
        --find-links /wheelhouse -r requirements.txt \
    && /opt/breeze/venv/bin/pip uninstall -y -q pip setuptools wheel 2>/dev/null || true
RUN find /opt/breeze/venv -type d -name '__pycache__' -prune -exec rm -rf {} + 2>/dev/null; \
    find /opt/breeze/venv -type d -name 'tests' -prune -exec rm -rf {} + 2>/dev/null; \
    true

########################  runtime  ########################
FROM alpine:edge AS runtime

ARG BREEZE_VERSION=0.0.0
ARG AC_COMMIT=""

# tzdata is not optional: schedules and curves run on naive local time, so
# without the zoneinfo database TZ=Europe/Zagreb quietly means UTC and every
# program fires hours off.
# su-exec is what lets the entrypoint start as root — apk and chowning a fresh
# volume both need it — and then hand the server itself to an unprivileged
# account for the whole of its life.
RUN apk add --no-cache python3 libffi openssl ca-certificates tzdata su-exec \
    && addgroup -g 1001 -S breeze \
    && adduser -S -D -H -u 1001 -G breeze -s /sbin/nologin breeze \
    && mkdir -p /etc/breeze-core \
    && chown -R 1001:1001 /etc/breeze-core && chmod 750 /etc/breeze-core

# The pin, applied to /etc/apk/world so that every later `apk upgrade` — from
# the self-updater or from a human — honours it. `apk add python3=~3.14` fails
# outright for a series Edge no longer carries ("breaks: world[python3~3.12]"),
# which is why the minor is discovered here rather than hardcoded.
RUN PYMINOR="$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])')" \
    && apk add --no-cache "python3=~${PYMINOR}" \
    && echo "  python3 pinned: $(grep python3 /etc/apk/world)"

COPY --from=builder /opt/breeze/venv /opt/breeze/venv
COPY meow_ac /opt/breeze/app/meow_ac
COPY static /opt/breeze/app/static
COPY setup_device.py requirements.txt /opt/breeze/app/

COPY containers/common/entrypoint   /usr/local/bin/breeze-entrypoint
COPY containers/common/breeze-setup /usr/local/bin/breeze-setup
COPY containers/common/breeze-core  /usr/local/bin/breeze-core
COPY containers/alpine/edge-update  /usr/local/bin/edge-update

# Explicit modes: the build context comes off a Windows filesystem, which records
# no POSIX execute bit, so a COPY'd script arrives non-executable and the
# container dies at start on "permission denied" running its own entrypoint.
RUN chmod 755 /usr/local/bin/breeze-core /usr/local/bin/breeze-entrypoint \
              /usr/local/bin/breeze-setup /usr/local/bin/edge-update

RUN { \
      echo "BREEZE_IMAGE='alpine-edge-$(apk --print-arch)'"; \
      echo "BREEZE_VERSION='${BREEZE_VERSION}'"; \
      echo "BREEZE_BASE='Alpine Edge $(cat /etc/alpine-release)'"; \
      echo "BREEZE_LIBC='musl'"; \
      echo "BREEZE_PYTHON='$(python3 -c 'import sys; print("%d.%d.%d" % sys.version_info[:3])')'"; \
      echo "BREEZE_NGINX='false'"; \
      echo "BREEZE_EDGE_UPDATE='start'"; \
      echo "BREEZE_COMMIT='${AC_COMMIT}'"; \
    } > /etc/breeze-image.env

LABEL org.opencontainers.image.title="Breeze Core — Alpine Edge (musl)" \
      org.opencontainers.image.description="LAN-first REST API + web panel for Midea air conditioners. Alpine Edge, musl, rolling base that upgrades its own packages on start (BREEZE_EDGE_UPDATE=off|start|daily). Built for x86_64 and arm64. First-time setup: docker exec -it <container> breeze-setup" \
      org.opencontainers.image.source="https://github.com/monikapurpl3/breeze-core" \
      org.opencontainers.image.licenses="AGPL-3.0-or-later" \
      org.opencontainers.image.version="${BREEZE_VERSION}" \
      org.opencontainers.image.revision="${AC_COMMIT}" \
      org.opencontainers.image.base.name="alpine:edge" \
      org.breeze.image="alpine-edge" \
      org.breeze.libc="musl" \
      org.breeze.nginx="false" \
      org.breeze.selfupdate="apk, python pinned to its minor series" \
      org.breeze.setup="docker exec -it <container> breeze-setup"

WORKDIR /opt/breeze/app
ENV PATH="/opt/breeze/venv/bin:$PATH" \
    PYTHONPATH=/opt/breeze/app \
    PYTHONUNBUFFERED=1 \
    AC_COMMIT=$AC_COMMIT \
    AC_CONFIG=/etc/breeze-core/config.json \
    AC_DEVICES=/etc/breeze-core/devices.json \
    AC_PROGRAMS=/etc/breeze-core/programs.json \
    BREEZE_EDGE_UPDATE=start

VOLUME ["/etc/breeze-core"]
EXPOSE 8420

# No USER: the entrypoint starts as root purely to run apk and to fix the owner
# of a fresh volume, then execs the server through su-exec as uid 1001. Start the
# container with --user 1001 to skip both — the self-updater then reports itself
# skipped, which is honest, rather than failing silently.

HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
    CMD ["/opt/breeze/venv/bin/python3","-c","import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8420/',timeout=3).status==200 else 1)"]

ENTRYPOINT ["/usr/local/bin/breeze-entrypoint"]
CMD ["/opt/breeze/venv/bin/uvicorn","meow_ac.app:app","--host","0.0.0.0","--port","8420"]
