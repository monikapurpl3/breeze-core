# syntax=docker/dockerfile:1
#
# Breeze Core — Alpine Edge + bundled nginx (TLS terminated in the container).
#
#   # build the Alpine image first, then this on top of it:
#   docker build -f containers/alpine/Dockerfile       -t breeze-core:alpine-edge-x86_64 .
#   docker build -f containers/alpine-nginx/Dockerfile -t breeze-core:alpine-edge-nginx-x86_64 .
#
# A thin layer over image 3 rather than a fourth copy of the build: same venv,
# same self-update, same setup script, plus nginx, a certificate and a
# supervisor. `--build-arg BASE_IMAGE=...` if the base is tagged differently.
#
# WHY THIS EXISTS: the app deliberately speaks plain HTTP and expects a proxy in
# front of it. That is right for a serious deployment and tedious for one air
# conditioner in a flat, where the honest options are "http over the LAN" or "go
# and learn nginx". This image is the third option: HTTPS on first start, one
# self-signed certificate in the state volume, SSE and the proxy headers already
# correct.

ARG BASE_IMAGE=breeze-core:alpine-edge-x86_64
FROM ${BASE_IMAGE}

ARG BREEZE_VERSION=0.0.0
ARG AC_COMMIT=""

USER root

RUN apk add --no-cache nginx openssl

COPY containers/alpine-nginx/nginx.conf      /etc/nginx/nginx.conf
COPY containers/alpine-nginx/breeze-tls-init /usr/local/bin/breeze-tls-init
COPY containers/alpine-nginx/supervise       /usr/local/bin/breeze-supervise

# Explicit modes: the build context comes off a Windows filesystem, which records
# no POSIX execute bit, so a COPY'd script arrives non-executable.
RUN chmod 755 /usr/local/bin/breeze-tls-init /usr/local/bin/breeze-supervise \
    && chmod 644 /etc/nginx/nginx.conf \
    # nginx as an unprivileged process: everything it writes at runtime lives
    # under /tmp/nginx (see nginx.conf).
    #
    # /var/log/nginx is named explicitly, and that is not redundant: nginx was
    # COMPILED with its error log at /var/lib/nginx/logs/error.log and opens
    # that path before reading a line of configuration, so an unwritable one
    # alerts on every start even though error_log says stderr. On Alpine
    # /var/lib/nginx/logs is a SYMLINK to /var/log/nginx, and chown -R does not
    # follow symlinks -- so chowning /var/lib/nginx alone changes nothing at all.
    && mkdir -p /tmp/nginx /var/lib/nginx/tmp /var/log/nginx \
    && chown -R 1001:1001 /tmp/nginx /var/lib/nginx /var/log/nginx

# Rewrite the identity: this is a different image and has to say so, in the
# banner, in breeze-setup (which grows a TLS step when BREEZE_NGINX is true) and
# in `docker inspect`.
RUN sed -i "s/^BREEZE_IMAGE=.*/BREEZE_IMAGE='alpine-edge-nginx-$(apk --print-arch)'/" /etc/breeze-image.env \
    && sed -i "s/^BREEZE_NGINX=.*/BREEZE_NGINX='true'/" /etc/breeze-image.env \
    && { \
         echo "BREEZE_HTTPS_PORT='8443'"; \
         echo "BREEZE_SETUP_BASE_URL='http://127.0.0.1:8420'"; \
       } >> /etc/breeze-image.env

LABEL org.opencontainers.image.title="Breeze Core — Alpine Edge + nginx (HTTPS)" \
      org.opencontainers.image.description="LAN-first REST API + web panel for Midea air conditioners, with nginx bundled: HTTPS on :8443 from the first start, self-signed certificate generated into the state volume, SSE and proxy headers already correct. Alpine Edge, musl, x86_64. First-time setup (includes TLS): docker exec -it <container> breeze-setup" \
      org.opencontainers.image.version="${BREEZE_VERSION}" \
      org.opencontainers.image.revision="${AC_COMMIT}" \
      org.breeze.image="alpine-edge-nginx" \
      org.breeze.libc="musl" \
      org.breeze.nginx="true" \
      org.breeze.https-port="8443" \
      org.breeze.selfupdate="apk, python pinned to its minor series" \
      org.breeze.setup="docker exec -it <container> breeze-setup"

# The app itself only ever listens on loopback here; nginx is the way in.
ENV AC_BEHIND_PROXY=1 \
    BREEZE_PUBLIC_HTTPS_PORT=8443
EXPOSE 8443 8080

# Through nginx, over TLS, so the healthcheck exercises the path a browser
# actually takes -- a cert or proxy mistake shows up as unhealthy instead of
# only being discovered by a person. --insecure because the certificate is
# self-signed by design; this is a loopback check, not a trust decision.
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
    CMD ["/bin/sh","-c","wget -q --no-check-certificate -O /dev/null https://127.0.0.1:8443/ || exit 1"]

ENTRYPOINT ["/usr/local/bin/breeze-entrypoint"]
CMD ["/usr/local/bin/breeze-supervise"]
