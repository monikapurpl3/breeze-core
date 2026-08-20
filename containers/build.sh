#!/usr/bin/env bash
# Build the five Breeze Core images. Local by default; --push publishes.
#
#   containers/build.sh                 # all five, into the local docker store
#   containers/build.sh ubi9-v3         # just one
#   containers/build.sh --push          # build and push, plus the manifest lists
#
# The five, and why each exists:
#
#   ubi9-x86-64-v2            glibc, broadest x86-64 — the conservative choice
#   ubi9-x86-64-v3            same, compiled for AVX2-era CPUs
#   alpine-edge-x86_64        musl, rolling, self-updating
#   alpine-edge-aarch64       ditto for arm64 (Pi 4/5, ARM servers)
#   alpine-edge-nginx-x86_64  the above + nginx, so HTTPS works out of the box
#
# Tags are deliberately self-describing: a rolling one (ubi9-x86-64-v2) and a
# pinned one (ubi9-x86-64-v2-3.1.0) for each. Nobody should have to guess what
# "latest-x86-64-v2" was supposed to mean, which is what the old scheme did.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"; cd "$REPO"
VER="$(sed -n 's/^__version__ = "\(.*\)"/\1/p' meow_ac/__init__.py)"
SHA="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
REGISTRY="${REGISTRY:-ghcr.io/monikapurpl3/breeze-core}"
LOCAL="${LOCAL_IMAGE:-breeze-core}"

PUSH=0
# The -<version> tags are meant to be pinnable, so CI only pushes them for an
# actual release tag: VERSION_TAG=0 on ordinary main builds, or every commit
# would quietly move ...-3.1.0 to something that is not 3.1.0's release.
VERSION_TAG="${VERSION_TAG:-1}"
WANT=()
for a in "$@"; do
    case "$a" in
        --push) PUSH=1 ;;
        --no-version-tag) VERSION_TAG=0 ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        *) WANT+=("$a") ;;
    esac
done
# 'manifests' is a pseudo-target: the multi-arch lists can only be assembled in a
# registry, from images pushed by other jobs, so CI runs it as its own step.
[ ${#WANT[@]} -eq 0 ] && WANT=(ubi9-v2 ubi9-v3 alpine-amd64 alpine-arm64 alpine-nginx manifests)

wanted() { for w in "${WANT[@]}"; do [ "$w" = "$1" ] && return 0; done; return 1; }

# Every build gets both tags, and --push sends them to the registry too. Kept in
# one function so a tag scheme change happens in exactly one place.
tags_for() {
    local base="$1"
    printf -- '-t %s:%s ' "$LOCAL" "$base"
    [ "$VERSION_TAG" = 1 ] && printf -- '-t %s:%s-%s ' "$LOCAL" "$base" "$VER"
    if [ "$PUSH" = 1 ]; then
        printf -- '-t %s:%s ' "$REGISTRY" "$base"
        [ "$VERSION_TAG" = 1 ] && printf -- '-t %s:%s-%s ' "$REGISTRY" "$base" "$VER"
    fi
    return 0
}

build() {  # build <dockerfile> <tag-base> <platform> [extra build args...]
    local file="$1" base="$2" plat="$3"; shift 3
    echo "==> $base  ($plat)" >&2
    # --load is not redundant. With a buildx builder (the docker-container
    # driver, which is what CI gets from setup-buildx-action) a tagged build
    # stays in the build cache and never reaches the local image store -- so the
    # nginx image cannot find its base by name, `docker push` has nothing to
    # push, and test.sh reports every image as "not built". Harmless with the
    # plain docker driver, load-bearing with any other.
    # shellcheck disable=SC2046  # tags_for deliberately expands to many args
    docker build --load --platform "$plat" -f "$file" \
        $(tags_for "$base") \
        --build-arg "BREEZE_VERSION=$VER" --build-arg "AC_COMMIT=$SHA" \
        "$@" . >&2
    if [ "$PUSH" = 1 ]; then
        docker push -q "$REGISTRY:$base"
        [ "$VERSION_TAG" = 1 ] && docker push -q "$REGISTRY:$base-$VER"
    fi
    return 0
}

wanted ubi9-v2  && build containers/ubi9/Dockerfile  ubi9-x86-64-v2 linux/amd64 \
                        --build-arg ARCH_LEVEL=x86-64-v2
wanted ubi9-v3  && build containers/ubi9/Dockerfile  ubi9-x86-64-v3 linux/amd64 \
                        --build-arg ARCH_LEVEL=x86-64-v3
wanted alpine-amd64 && build containers/alpine/Dockerfile alpine-edge-x86_64  linux/amd64
wanted alpine-arm64 && build containers/alpine/Dockerfile alpine-edge-aarch64 linux/arm64

# The nginx image layers on the amd64 Alpine one, so that has to exist first --
# by name, in the local store. Building it standalone would mean a second copy
# of the whole venv build for no reason.
if wanted alpine-nginx; then
    docker image inspect "$LOCAL:alpine-edge-x86_64" >/dev/null 2>&1 || \
        build containers/alpine/Dockerfile alpine-edge-x86_64 linux/amd64
    build containers/alpine-nginx/Dockerfile alpine-edge-nginx-x86_64 linux/amd64 \
        --build-arg "BASE_IMAGE=$LOCAL:alpine-edge-x86_64"
fi

# Manifest lists can only be assembled in a registry, from images that are
# already pushed, so this is a separate target CI runs after the per-arch jobs.
# `alpine-edge` — and `latest`, which points at the same thing — is the only tag
# that resolves on both architectures: the UBI images are x86-64-only by
# construction, psABI levels being an x86 concept.
if wanted manifests && [ "$PUSH" = 1 ]; then
    lists=("alpine-edge" "latest")
    [ "$VERSION_TAG" = 1 ] && lists+=("alpine-edge-$VER")
    for m in "${lists[@]}"; do
        docker buildx imagetools create -t "$REGISTRY:$m" \
            "$REGISTRY:alpine-edge-x86_64" "$REGISTRY:alpine-edge-aarch64"
        echo "    manifest $m -> x86_64 + aarch64" >&2
    done
    echo "==> $REGISTRY:latest is the multi-arch Alpine Edge pair" >&2
fi

echo "==> done: $VER ($SHA)" >&2
docker images "$LOCAL" --format '    {{.Tag}}\t{{.Size}}' | sort >&2
