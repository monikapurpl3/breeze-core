# syntax=docker/dockerfile:1
#
# Breeze Core — Red Hat UBI 9, x86-64 psABI level v2 or v3.
#
#   docker build -f containers/ubi9/Dockerfile --build-arg ARCH_LEVEL=x86-64-v2 .
#   docker build -f containers/ubi9/Dockerfile --build-arg ARCH_LEVEL=x86-64-v3 .
#
# amd64 only, by construction: psABI levels are an x86-64 concept. arm64 users
# want the Alpine Edge image (containers/alpine/), which is built for both.
#
# WHY BUILD FROM SOURCE AT ALL: PyPI's manylinux wheels are compiled for the
# BASELINE x86-64 — no SSE4.2, no AVX2 — because they have to run anywhere.
# RHEL 9 itself already requires x86-64-v2, so the distro's own Python sits a
# level above the wheels it would install. This image closes that gap: every
# dependency carrying native code (pydantic-core, pycryptodome, uvloop,
# httptools, watchfiles, brotli, …) is compiled here at the level named above.
#
# The honest caveat: this workload is LAN-round-trip bound. Expect the gain to
# be small. The v3 image exists because the hardware is there, not because a
# profile demanded it.

ARG UBI_TAG=9.6

########################  builder  ########################
FROM registry.access.redhat.com/ubi9/ubi-minimal:${UBI_TAG} AS builder

ARG ARCH_LEVEL=x86-64-v2

# gcc 11 knows -march=x86-64-v2/v3/v4, and UBI 9 now ships rust 1.92, so the
# rustup bootstrap an earlier version of this image needed is gone — one less
# network dependency and one less thing to pin.
# NB: never ask for `curl` here — ubi-minimal ships curl-minimal, which already
# provides /usr/bin/curl, and requesting the full package starts a depsolve
# conflict.
RUN microdnf -y --nodocs --setopt=install_weak_deps=0 install \
        python3.12 python3.12-pip python3.12-devel \
        gcc gcc-c++ make openssl-devel libffi-devel \
        rust cargo tar gzip findutils \
    && microdnf clean all

ENV CFLAGS="-march=${ARCH_LEVEL} -O2" \
    CXXFLAGS="-march=${ARCH_LEVEL} -O2" \
    RUSTFLAGS="-C target-cpu=${ARCH_LEVEL}"

WORKDIR /build
COPY requirements.txt .

# A wheelhouse, not a direct install: the wheels get built once, named, and then
# installed offline into the runtime venv. That makes it possible to SEE what was
# built — containers/test.sh disassembles the resulting .so files and checks they
# really do carry the instructions this level promises — instead of trusting that
# a compiler flag reached a compiler somewhere inside a pip subprocess.
RUN python3.12 -m venv /opt/breeze/venv \
    && /opt/breeze/venv/bin/pip install -q --no-cache-dir --upgrade pip wheel \
    && /opt/breeze/venv/bin/pip wheel --no-cache-dir --no-binary :all: \
        -r requirements.txt -w /wheelhouse \
    && ls -1 /wheelhouse

RUN /opt/breeze/venv/bin/pip install -q --no-cache-dir --no-index \
        --find-links /wheelhouse -r requirements.txt \
    && /opt/breeze/venv/bin/pip uninstall -y -q pip setuptools wheel 2>/dev/null || true
RUN find /opt/breeze/venv -type d -name '__pycache__' -prune -exec rm -rf {} + 2>/dev/null; \
    find /opt/breeze/venv -type d -name 'tests' -prune -exec rm -rf {} + 2>/dev/null; \
    true

########################  runtime  ########################
FROM registry.access.redhat.com/ubi9/ubi-minimal:${UBI_TAG} AS runtime

ARG ARCH_LEVEL=x86-64-v2
ARG BREEZE_VERSION=0.0.0
ARG AC_COMMIT=""
ARG UBI_TAG=9.6

# tzdata is NOT in ubi-minimal, and its absence is a bug rather than a missing
# nicety: the scheduler works in naive local time, so with no zoneinfo database
# TZ=Europe/Zagreb silently resolves to UTC (time.tzname comes back as
# ('Europe','Europe')) and every schedule and curve fires hours off.
RUN microdnf -y --nodocs --setopt=install_weak_deps=0 install \
        python3.12 openssl-libs libffi tzdata \
    && microdnf clean all \
    && echo 'breeze:x:1001:0:Breeze Core:/opt/breeze:/sbin/nologin' >> /etc/passwd \
    && mkdir -p /etc/breeze-core \
    && chown -R 1001:0 /etc/breeze-core && chmod -R g=u /etc/breeze-core

COPY --from=builder /opt/breeze/venv /opt/breeze/venv
COPY meow_ac /opt/breeze/app/meow_ac
COPY static /opt/breeze/app/static
COPY setup_device.py requirements.txt /opt/breeze/app/

COPY containers/common/entrypoint   /usr/local/bin/breeze-entrypoint
COPY containers/common/breeze-setup /usr/local/bin/breeze-setup
COPY containers/common/breeze-core  /usr/local/bin/breeze-core

# Explicit modes: this build context comes off a Windows filesystem, which
# records no POSIX execute bit, so a COPY'd script arrives non-executable and
# the container dies at start with "permission denied" on its own entrypoint.
RUN chmod 755 /usr/local/bin/breeze-core /usr/local/bin/breeze-entrypoint \
              /usr/local/bin/breeze-setup

# The identity every image carries: read by the entrypoint banner and by
# breeze-setup, and available to anyone who types
# `docker exec <c> cat /etc/breeze-image.env`. Same facts as the labels below,
# in a form shell can read.
RUN { \
      echo "BREEZE_IMAGE='ubi9-${ARCH_LEVEL}'"; \
      echo "BREEZE_VERSION='${BREEZE_VERSION}'"; \
      echo "BREEZE_BASE='Red Hat UBI ${UBI_TAG}'"; \
      echo "BREEZE_LIBC='glibc'"; \
      echo "BREEZE_PYTHON='3.12'"; \
      echo "BREEZE_ARCH_LEVEL='${ARCH_LEVEL}'"; \
      echo "BREEZE_NGINX='false'"; \
      echo "BREEZE_EDGE_UPDATE='off'"; \
      echo "BREEZE_COMMIT='${AC_COMMIT}'"; \
      if [ "${ARCH_LEVEL}" = "x86-64-v3" ]; then \
        echo "BREEZE_REQUIRED_CPU_FLAGS='avx2,bmi2,fma,f16c'"; \
      else \
        echo "BREEZE_REQUIRED_CPU_FLAGS='sse4_2,popcnt'"; \
      fi; \
    } > /etc/breeze-image.env

LABEL org.opencontainers.image.title="Breeze Core — UBI 9 (${ARCH_LEVEL})" \
      org.opencontainers.image.description="LAN-first REST API + web panel for Midea air conditioners. Red Hat UBI 9, glibc, Python 3.12, every native dependency compiled for ${ARCH_LEVEL}. amd64 only. First-time setup: docker exec -it <container> breeze-setup" \
      org.opencontainers.image.source="https://github.com/monikapurpl3/breeze-core" \
      org.opencontainers.image.licenses="AGPL-3.0-or-later" \
      org.opencontainers.image.version="${BREEZE_VERSION}" \
      org.opencontainers.image.revision="${AC_COMMIT}" \
      org.opencontainers.image.base.name="registry.access.redhat.com/ubi9/ubi-minimal:${UBI_TAG}" \
      org.breeze.image="ubi9-${ARCH_LEVEL}" \
      org.breeze.libc="glibc" \
      org.breeze.python="3.12" \
      org.breeze.arch-level="${ARCH_LEVEL}" \
      org.breeze.nginx="false" \
      org.breeze.selfupdate="none" \
      org.breeze.setup="docker exec -it <container> breeze-setup"

WORKDIR /opt/breeze/app
ENV PATH="/opt/breeze/venv/bin:$PATH" \
    PYTHONPATH=/opt/breeze/app \
    PYTHONUNBUFFERED=1 \
    AC_COMMIT=$AC_COMMIT \
    AC_CONFIG=/etc/breeze-core/config.json \
    AC_DEVICES=/etc/breeze-core/devices.json \
    AC_PROGRAMS=/etc/breeze-core/programs.json

VOLUME ["/etc/breeze-core"]
EXPOSE 8420
USER 1001

HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
    CMD ["/opt/breeze/venv/bin/python3","-c","import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8420/',timeout=3).status==200 else 1)"]

ENTRYPOINT ["/usr/local/bin/breeze-entrypoint"]
# 0.0.0.0 is this container's own namespace, not your LAN. What decides exposure
# is how the port is published — see docs/DOCKER.md.
CMD ["/opt/breeze/venv/bin/uvicorn","meow_ac.app:app","--host","0.0.0.0","--port","8420"]
