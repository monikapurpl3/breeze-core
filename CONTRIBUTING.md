# Contributing to Breeze Core

Thanks for helping out! Breeze Core is the self-hosted server (REST API + web UI + CLIs) for controlling Midea air conditioners. The Android app lives in a separate repo, [breeze](https://github.com/monikapurpl3/breeze).

## Dev setup

```bash
python3 -m venv venv
./venv/bin/pip install -r requirements.txt

# run against a local config (AC_DOCS=1 re-enables /docs for dev):
AC_CONFIG=./config.json AC_DOCS=1 ./venv/bin/uvicorn meow_ac.app:app --host 127.0.0.1 --port 8420
```

You need real Midea units (and `setup_device.py` to pair them) to exercise device control end-to-end. Without hardware you can still work on and test everything else — auth/enrollment, programs/scheduler, config, and the API surface — by standing up the app with a temp `config.json` and a stub for `msmart`.

## Before you open a PR

- **Run the tests:** `python -m pytest tests/ -q` (28 tests, no hardware needed —
  `msmart` is stubbed). Install them first with
  `pip install -r requirements.txt -r requirements-dev.txt`; `pytest-asyncio` is
  required, and without it the async tests fail rather than skip.
- **Byte-compile:** `python -m compileall meow_ac setup_device.py` (CI does this).
- **Import check:** `AC_CONFIG=/tmp/x.json python -c "import meow_ac.app"` should succeed.
- If you touched the API, run the diagnostic CLI against a running instance: `./tools/ac-diag.zsh --base-url http://127.0.0.1:8420 --config ./config.json --auto`.
- Keep changes focused; describe what and why in the PR.

## Conventions (please match these)

The repo's [`CLAUDE.md`](CLAUDE.md) documents the architecture and the load-bearing conventions in detail. The short version:

- **Add through the seams.** New endpoint → a `build_*` router factory in `meow_ac/api/` wired in `create_app()`. New auth factor → implement the `Authenticator` protocol and compose it. Don't widen existing modules.
- **Never add CORS middleware** — its absence is intentional (same-origin UI).
- **Read enum members with `.name`, never `str()`** (Python 3.11 `IntEnum.__str__` change).
- **Preserve the wire contract** — the `serialize()` shape, `ControlRequest` fields, and error codes are depended on by the web UI, the CLIs, and the app.
- **Secrets** are compared constant-time and stored only hashed; keep it that way. Don't log keys/tokens.
- **Strict CSP** in the UI: keep CSS in `styles.css` and JS in modules — no inline styles/scripts.
- Keep [`https://github.com/monikapurpl3/breeze-core/wiki/Exposing-it-safely`](https://github.com/monikapurpl3/breeze-core/wiki/Exposing-it-safely) in sync when you change auth, settings, middleware, or the systemd unit.

## Which ports get rebuilt for a release

Not every port is rebuilt every time, and the tiers are deliberate — a release is
not blocked on the exotic ones.

**Tier 1 — every release, in this order.** The order matters: the first two cover
almost every real install, so they go out first and the rest follow.

1. `nfpm` packages (deb/rpm/apk/pacman) for **x86_64 + arm64**, plus the tarballs
   and the signed repo — `packaging/nfpm/build-packages.sh`, then
   `packaging/repo/build-repo.sh` and `publish.sh`.
2. **Windows** installer + winget manifests — `deploy/windows/build-installer.ps1`.
3. **BSD** — FreeBSD `.pkg` and NetBSD binary package, built on the VMs
   (`packaging/repo/build-bsd-repo.sh` stages them).
4. **OPNsense** — the `os-breeze-core` plugin: `packaging/opnsense/build-plugin.sh`
   then `verify-plugin.sh`. It needs its own build rather than the FreeBSD package
   because OPNsense is `FreeBSD:14:amd64` with python311 and neither rust nor pip,
   so the runtime is vendored — [https://github.com/monikapurpl3/breeze-core/wiki/Installing-on-OPNsense](https://github.com/monikapurpl3/breeze-core/wiki/Installing-on-OPNsense).
5. **OpenWrt** `.ipk` feed.

**Tier 2 — occasionally.** **Termux** (Android): every major version, or every
other. It is cheap now that pydantic-core is cross-compiled rather than built
under emulation (`packaging/termux/`), but it is not release-blocking.

**Tier 3 — frozen unless something major changes.** The proof-of-concept
architectures — MIPS (OpenWrt + Debian), ppc64le, s390x — stay at whatever
version they were last built for, and the published artifacts say so plainly.
They are developer aids, not a support commitment. Recipes and every trap:
[https://github.com/monikapurpl3/breeze-core/wiki/Proof-of-concept-architectures](https://github.com/monikapurpl3/breeze-core/wiki/Proof-of-concept-architectures).

**OPNsense is tier 1 as of 3.1.0**, listed above between BSD and OpenWrt. It is a
real plugin — a page under Services, service control through configd, an rc
script — not a `pkg add` of the FreeBSD package, because the ABI, the Python
version and the absent dependencies all differ. The GUI is the one part no
automated check covers: the PHP is lint-checked and the XML parsed, but the page
rendering has to be confirmed on a real firewall.

## Security

Please report vulnerabilities privately — see [SECURITY.md](SECURITY.md). Don't open a public issue for them.

## License

By contributing you agree your contributions are licensed under the project's **AGPL-3.0** ([LICENSE](LICENSE)).
