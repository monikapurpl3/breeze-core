#!/usr/bin/env bash
# Build the static, SIGNED package-repository tree from packaging/out/pkg/*.
#
# Everything runs in containers on the workstation; the signing keys live in
# packaging/repo/keys/ (git-ignored — BACK THEM UP) and are generated on
# first run. The output (packaging/out/repo/) is a plain static file tree:
# the web host that serves it never sees a private key.
#
#   packaging/out/repo/
#   ├── index.html  breeze-core.asc  alpine-key/breeze-core@bolero.rsa.pub
#   ├── deb/     dists/stable/... + pool/          (apt,  GPG InRelease)
#   ├── rpm/     {x86_64,aarch64}/ + repodata/     (dnf/zypper, signed rpms + repomd.xml.asc)
#   ├── arch/    {x86_64,aarch64}/breeze-core.db…  (pacman, signed db + pkgs)
#   └── alpine/  {x86_64,aarch64}/APKINDEX.tar.gz  (apk, RSA-signed index)
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO"
VER="$(sed -n 's/^__version__ = "\(.*\)"/\1/p' meow_ac/__init__.py)"
PKG="packaging/out/pkg"
OUT="packaging/out/repo"
KEYS="packaging/repo/keys"
GPG_UID="Breeze Core Repository <repo@bolero.salataputarica.hr.eu.org>"
APK_KEY_NAME="breeze-core@bolero"

MOUNT="$REPO"
case "$MOUNT" in /[a-z]/*) MOUNT="$(echo "$MOUNT" | sed -E 's#^/([a-z])/#\U\1:/#')" ;; esac
drun() { MSYS_NO_PATHCONV=1 docker run --rm -v "$MOUNT:/work" -w /work "$@"; }

[ -e "$PKG/breeze-core_${VER}_amd64.deb" ] || { echo "no packages for $VER — run build-packages.sh first"; exit 1; }

# --- keys (generated once; keep keys/ backed up and OUT of git) --------------
mkdir -p "$KEYS"
if [ ! -f "$KEYS/gpg-private.asc" ]; then
  echo "=== generating repo GPG key (first run) ==="
  drun debian:bookworm-slim bash -c '
    set -e
    apt-get -qq update >/dev/null && apt-get -qq install -y gnupg >/dev/null
    export GNUPGHOME=$(mktemp -d)
    gpg --batch --quiet --gen-key <<EOF
%no-protection
Key-Type: eddsa
Key-Curve: ed25519
Subkey-Type: eddsa
Subkey-Curve: ed25519
Name-Real: Breeze Core Repository
Name-Email: repo@bolero.salataputarica.hr.eu.org
Expire-Date: 0
%commit
EOF
    gpg --batch --armor --export-secret-keys > /work/packaging/repo/keys/gpg-private.asc
    gpg --batch --armor --export > /work/packaging/repo/keys/gpg-public.asc
    gpg --list-keys --with-colons | awk -F: "/^fpr/{print \$10; exit}" > /work/packaging/repo/keys/gpg-fingerprint.txt
  '
fi
if [ ! -f "$KEYS/$APK_KEY_NAME.rsa" ]; then
  echo "=== generating Alpine RSA key (first run) ==="
  drun alpine:3.20 sh -c "
    apk add --no-cache openssl >/dev/null
    openssl genrsa -out '/work/$KEYS/$APK_KEY_NAME.rsa' 4096 2>/dev/null
    openssl rsa -in '/work/$KEYS/$APK_KEY_NAME.rsa' -pubout -out '/work/$KEYS/$APK_KEY_NAME.rsa.pub' 2>/dev/null
  "
fi

rm -rf "$OUT"; mkdir -p "$OUT"
cp "$KEYS/gpg-public.asc" "$OUT/breeze-core.asc"
mkdir -p "$OUT/alpine"
cp "$KEYS/$APK_KEY_NAME.rsa.pub" "$OUT/alpine/$APK_KEY_NAME.rsa.pub"

# --- apt (deb) ----------------------------------------------------------------
echo "=== apt repo ==="
drun debian:bookworm-slim bash -c '
  set -e
  apt-get -qq update >/dev/null && apt-get -qq install -y apt-utils gnupg >/dev/null
  export GNUPGHOME=$(mktemp -d)
  gpg --batch --quiet --import /work/packaging/repo/keys/gpg-private.asc

  R=/work/packaging/out/repo/deb
  mkdir -p "$R/pool/main/b/breeze-core"
  cp /work/packaging/out/pkg/*.deb "$R/pool/main/b/breeze-core/"
  cd "$R"
  for a in amd64 arm64; do
    mkdir -p "dists/stable/main/binary-$a"
    apt-ftparchive --arch "$a" packages pool > "dists/stable/main/binary-$a/Packages"
    gzip -9kf "dists/stable/main/binary-$a/Packages"
  done
  cd dists/stable
  apt-ftparchive \
    -o APT::FTPArchive::Release::Origin="Breeze Core" \
    -o APT::FTPArchive::Release::Label="Breeze Core" \
    -o APT::FTPArchive::Release::Suite=stable \
    -o APT::FTPArchive::Release::Codename=stable \
    -o APT::FTPArchive::Release::Architectures="amd64 arm64" \
    -o APT::FTPArchive::Release::Components=main \
    release . > Release
  gpg --batch --yes --clearsign -o InRelease Release
  gpg --batch --yes -abs -o Release.gpg Release
'

# --- rpm (dnf/zypper) ----------------------------------------------------------
echo "=== rpm repo ==="
drun almalinux:9 bash -c '
  set -e
  dnf -q install -y createrepo_c rpm-sign gnupg2 >/dev/null
  export GNUPGHOME=$(mktemp -d)
  gpg --batch --quiet --import /work/packaging/repo/keys/gpg-private.asc
  cat > ~/.rpmmacros <<EOF
%_signature gpg
%_gpg_name Breeze Core Repository
EOF
  # Work on a container-local fs: rpmsign replaces files via rename, which
  # fails on the Windows bind mount. Copy the finished tree out at the end.
  W=/tmp/rpmrepo
  mkdir -p "$W/x86_64" "$W/aarch64"
  cp /work/packaging/out/pkg/*.x86_64.rpm  "$W/x86_64/"
  cp /work/packaging/out/pkg/*.aarch64.rpm "$W/aarch64/"
  for a in x86_64 aarch64; do
    rpmsign --addsign "$W/$a/"*.rpm >/dev/null
    createrepo_c --general-compress-type gz "$W/$a" >/dev/null
    gpg --batch --yes -abs -o "$W/$a/repodata/repomd.xml.asc" "$W/$a/repodata/repomd.xml"
  done
  mkdir -p /work/packaging/out/repo
  cp -R "$W" /work/packaging/out/repo/rpm
'

# --- pacman (arch) --------------------------------------------------------------
echo "=== pacman repo ==="
drun archlinux:base bash -c '
  set -e
  export GNUPGHOME=$(mktemp -d)
  gpg --batch --quiet --import /work/packaging/repo/keys/gpg-private.asc
  W=/tmp/archrepo
  mkdir -p "$W/x86_64" "$W/aarch64"
  cp /work/packaging/out/pkg/*-x86_64.pkg.tar.zst  "$W/x86_64/"
  cp /work/packaging/out/pkg/*-aarch64.pkg.tar.zst "$W/aarch64/"
  KEYID="$(gpg --list-keys --with-colons | awk -F: "/^fpr/{print \$10; exit}")"
  for a in x86_64 aarch64; do (
    cd "$W/$a"
    for p in *.pkg.tar.zst; do gpg --batch --yes --detach-sign "$p"; done
    repo-add --sign --key "$KEYID" breeze-core.db.tar.gz *.pkg.tar.zst >/dev/null
  ); done
  cp -RL "$W" /work/packaging/out/repo/arch   # -L: materialize the .db symlinks
'

# --- apk (alpine) ----------------------------------------------------------------
echo "=== apk repo ==="
drun alpine:3.20 sh -c "
  set -e
  apk add --no-cache abuild apk-tools >/dev/null
  W=/tmp/apkrepo
  mkdir -p \"\$W/x86_64\" \"\$W/aarch64\"
  # apk fetches packages as <name>-<V-field>.apk — the file name MUST
  # match the index V: exactly (nfpm emits V without -rN), so rename accordingly.
  VER='$VER'
  cp /work/packaging/out/pkg/breeze-core_\${VER}_x86_64.apk  \"\$W/x86_64/breeze-core-\${VER}.apk\"
  cp /work/packaging/out/pkg/breeze-core_\${VER}_aarch64.apk \"\$W/aarch64/breeze-core-\${VER}.apk\"
  for a in x86_64 aarch64; do (
    cd \"\$W/\$a\"
    apk index --allow-untrusted --rewrite-arch \$a -o APKINDEX.tar.gz *.apk 2>/dev/null
    abuild-sign -k '/work/$KEYS/$APK_KEY_NAME.rsa' APKINDEX.tar.gz
  ); done
  mkdir -p /work/packaging/out/repo/alpine
  cp -R \"\$W\"/. /work/packaging/out/repo/alpine/
"

# --- landing page ---------------------------------------------------------------
sed "s/@VERSION@/$VER/g" packaging/repo/index.html > "$OUT/index.html"

echo ""
echo "== $OUT =="
find "$OUT" -type f | sed "s|$OUT/|  |" | sort
echo ""
echo "repo tree built and signed for v$VER. Publish with packaging/repo/publish.sh"
