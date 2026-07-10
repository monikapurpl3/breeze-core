# packaging/ — self-contained builds + native packages

Binary-first pipeline: build the app **once per (libc, arch)** as a
self-contained PyInstaller bundle, wrap those four bundles into every native
package format, then install-test the results on real distro userlands.
User docs: [docs/PACKAGES.md](../docs/PACKAGES.md).

```
binary/    launcher.py (serve/pair/version CLI), PyInstaller spec,
           Dockerfile.glibc (AlmaLinux 8 → runs on any glibc ≥ 2.28),
           Dockerfile.musl (Alpine), build-binaries.sh (buildx, arm64 via QEMU)
nfpm/      nfpm.yaml + service files + pre/post scripts + package-one.sh
           → .deb  .rpm  .pkg.tar.zst  .apk   (build-packages.sh)
tarball/   install.sh — generic Linux installer (systemd/OpenRC/runit detect)
test/      test-matrix.sh — installs the packages on 15 distro images and
           verifies binary + service user + perms + server startup
source/    recipes for packagers: Arch PKGBUILD (source venv build),
           Gentoo -bin ebuild (+acct-user/group), Void xbps-src template
../flake.nix   Nix flake (source build) + NixOS module
```

Local workflow (workstation, Docker Desktop):

```bash
./packaging/binary/build-binaries.sh     # 4 bundles  -> packaging/out/bundle-*
./packaging/nfpm/build-packages.sh       # 12 artifacts -> packaging/out/pkg/
./packaging/test/test-matrix.sh          # 15-target install-test matrix
./packaging/repo/build-repo.sh           # signed apt/rpm/pacman/apk repo tree
./packaging/repo/publish.sh              # push to the package host (atomic swap)
```

CI (`.github/workflows/packages.yml`) runs the same three scripts on `v*` tags
and attaches `packaging/out/pkg/*` to the GitHub release.

Known quirks (documented in the scripts): nfpm 2.47's apk packager rejects
`type: tree` (per-file entries are generated instead; see upstream issue),
staging must `cp -RL` (PyInstaller bundles carry a symlink) and normalize
modes (a Windows checkout loses exec bits).
