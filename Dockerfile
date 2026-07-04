# syntax=docker/dockerfile:1
#
# Breeze Core container — Red Hat UBI 9 minimal (free & redistributable,
# glibc so Python wheels work, security-patched by Red Hat). Multi-stage:
# deps are built in a throwaway stage; the runtime image is minimal and
# runs as a non-root user.

########################  builder  ########################
FROM registry.access.redhat.com/ubi9/ubi-minimal:latest AS builder

RUN microdnf install -y python3.11 python3.11-pip python3.11-devel gcc \
    && microdnf clean all

WORKDIR /app
COPY requirements.txt .
RUN python3.11 -m venv /opt/venv \
    && /opt/venv/bin/pip install --no-cache-dir --upgrade pip \
    && /opt/venv/bin/pip install --no-cache-dir -r requirements.txt \
    # slim the runtime venv: build/install tooling and caches aren't needed
    && /opt/venv/bin/pip uninstall -y pip setuptools wheel 2>/dev/null || true \
    && find /opt/venv -type d -name '__pycache__' -prune -exec rm -rf {} + \
    && find /opt/venv -type d -name 'tests' -prune -exec rm -rf {} +

########################  runtime  ########################
FROM registry.access.redhat.com/ubi9/ubi-minimal:latest AS runtime

LABEL org.opencontainers.image.title="Breeze Core" \
      org.opencontainers.image.description="Self-hosted, LAN-first REST API + web panel for controlling Midea air conditioners." \
      org.opencontainers.image.source="https://github.com/monikapurpl3/breeze-core" \
      org.opencontainers.image.licenses="AGPL-3.0-or-later"

# Runtime needs only the interpreter (deps come prebuilt in the venv).
# A non-root account in group 0 with a group-writable state dir keeps the
# image safe and OpenShift/arbitrary-UID friendly — no shadow-utils needed.
RUN microdnf install -y python3.11 && microdnf clean all \
    && echo 'breeze:x:1001:0:Breeze:/app:/sbin/nologin' >> /etc/passwd \
    && mkdir -p /etc/breeze-core \
    && chown -R 1001:0 /etc/breeze-core && chmod -R g=u /etc/breeze-core

COPY --from=builder /opt/venv /opt/venv

WORKDIR /app
COPY meow_ac ./meow_ac
COPY static ./static
COPY setup_device.py requirements.txt ./

ENV PATH="/opt/venv/bin:$PATH" \
    PYTHONUNBUFFERED=1 \
    AC_CONFIG=/etc/breeze-core/config.json \
    AC_DEVICES=/etc/breeze-core/devices.json \
    AC_PROGRAMS=/etc/breeze-core/programs.json

VOLUME ["/etc/breeze-core"]
EXPOSE 8420
USER 1001

# The static UI ("/") answers 200 without auth as soon as the app is up.
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD ["python3.11","-c","import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8420/',timeout=3).status==200 else 1)"]

# Binds 0.0.0.0 *inside the container* (isolated). Do NOT publish this port
# raw to the internet — front it with the reverse proxy (see docs/DOCKER.md
# and docs/REVERSE-PROXY.md). Override with your own --host as needed.
CMD ["uvicorn","meow_ac.app:app","--host","0.0.0.0","--port","8420"]
