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
- Keep [`HARDENING.md`](HARDENING.md) in sync when you change auth, settings, middleware, or the systemd unit.

## Security

Please report vulnerabilities privately — see [SECURITY.md](SECURITY.md). Don't open a public issue for them.

## License

By contributing you agree your contributions are licensed under the project's **AGPL-3.0** ([LICENSE](LICENSE)).
