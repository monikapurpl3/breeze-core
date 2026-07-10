# syntax=docker/dockerfile:1
# Packaging container: nfpm + shell tools, used by build-packages.sh to
# normalize bundle file modes on a Linux filesystem (the Windows checkout
# loses the exec bit) and emit deb/rpm/apk/pacman packages + tarballs.
FROM alpine:3.20

ARG NFPM_VERSION=2.47.0
RUN apk add --no-cache bash tar zstd curl \
    && arch="$(apk --print-arch)" \
    && case "$arch" in x86_64) na=x86_64 ;; aarch64) na=arm64 ;; *) na="$arch" ;; esac \
    && curl -fsSL "https://github.com/goreleaser/nfpm/releases/download/v${NFPM_VERSION}/nfpm_${NFPM_VERSION}_Linux_${na}.tar.gz" \
       | tar -xz -C /usr/local/bin nfpm \
    && nfpm --version
WORKDIR /work
