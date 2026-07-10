# packaging/repo — the signed package repository

Static apt/dnf/pacman/apk repositories served from
`https://bolero.salataputarica.hr.eu.org` so end users install and **update
Breeze Core through their package manager** instead of downloading release
assets by hand.

## Security model

- The tree is **built and signed on the maintainer workstation** in
  containers (`build-repo.sh`). The private keys live in `keys/` here —
  git-ignored, **back them up**; losing them means every user must re-trust a
  new key.
- The web host serves **static files only** — it never holds a key. A
  compromised host can serve stale/broken files but cannot forge packages:
  apt verifies the GPG-signed `InRelease`, dnf/zypper verify signed rpms +
  `repomd.xml.asc` (`repo_gpgcheck=1`), pacman requires signed db + packages
  (`SigLevel = Required`), apk verifies the RSA-signed `APKINDEX`.
- Publishing swaps a `current` symlink atomically and keeps the last 3
  releases under `releases/` for instant rollback.

## Release flow (after build-binaries.sh + build-packages.sh)

```bash
./packaging/repo/build-repo.sh     # build + sign the tree  -> packaging/out/repo/
./packaging/repo/publish.sh        # push + atomic swap + smoke check
```

Keys are generated on first `build-repo.sh` run: an ed25519 GPG key
(apt/rpm/pacman) and a 4096-bit RSA key (apk — apk-tools requires RSA). The
public halves are published in the tree as `/breeze-core.asc` and
`/alpine/breeze-core@bolero.rsa.pub`.

## Host layout (one-time setup, done 2026-07-10)

- `/var/www/bolero/{releases/<ts>, current -> releases/<ts>}`, owned by the
  push user, so publishing needs **no sudo**.
- nginx vhost `bolero.conf`: TLS (certbot), static-only with `autoindex`,
  dedicated access log, rate + connection limits, no proxying.
- End-user instructions live on the repo landing page (`index.html`) and in
  [docs/PACKAGES.md](../../docs/PACKAGES.md).
