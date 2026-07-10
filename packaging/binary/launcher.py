"""
breeze-core — single-binary launcher for the self-contained bundles.

This is the entry point PyInstaller freezes. It gives the bundle the same
"all-in-one" feel as the Windows installer:

    breeze-core serve   [--host H] [--port P] [--behind-proxy]
    breeze-core pair    [--ip IP] [--no-prompt] [--out PATH]
    breeze-core version

It deliberately contains no logic of its own — serve wraps uvicorn around the
normal `meow_ac.app.create_app()`, pair calls `setup_device.main()`, version
reads the same metadata `/api/version` serves. Env vars (`AC_*`) work exactly
as documented; the only launcher-added behaviour is a packaging-friendly
default of AC_CONFIG=/etc/breeze-core/config.json (the path the distro
packages create) instead of the bare-source /etc/meow-ac default.
"""
from __future__ import annotations

import argparse
import asyncio
import os
import sys
from pathlib import Path

# Packages create /etc/breeze-core (see packaging/nfpm); make the binary's
# default match it. An explicit AC_CONFIG always wins.
os.environ.setdefault("AC_CONFIG", "/etc/breeze-core/config.json")


def _version_info() -> str:
    from meow_ac import __version__
    from meow_ac.api.meta import _commit

    return f"Breeze Core {__version__} (commit {_commit()})"


def cmd_serve(args: argparse.Namespace) -> int:
    import uvicorn

    from meow_ac.app import create_app

    kwargs = {}
    if args.behind_proxy:
        # Trust X-Forwarded-For only from the local reverse proxy, and tell
        # the app to read it (same flags the systemd/NSSM setups use).
        os.environ.setdefault("AC_BEHIND_PROXY", "1")
        kwargs = {"proxy_headers": True, "forwarded_allow_ips": "127.0.0.1"}

    app = create_app()
    # Single worker by design: the in-process scheduler must be a singleton.
    uvicorn.run(app, host=args.host, port=args.port, log_level="info", **kwargs)
    return 0


def cmd_pair(args: argparse.Namespace) -> int:
    import setup_device

    out = Path(args.out) if args.out else Path(os.environ["AC_CONFIG"])
    out.parent.mkdir(parents=True, exist_ok=True)
    asyncio.run(setup_device.main(args.ip, out, interactive_names=not args.no_prompt))
    return 0


def cmd_version(_args: argparse.Namespace) -> int:
    print(_version_info())
    return 0


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="breeze-core",
        description="Self-hosted, LAN-first control for Midea air conditioners.",
        epilog="Configuration via AC_* environment variables — see the README.",
    )
    sub = p.add_subparsers(dest="command")

    s = sub.add_parser("serve", help="run the API + web UI (foreground)")
    s.add_argument("--host", default="127.0.0.1",
                   help="bind address (LAN IP for direct use, 127.0.0.1 behind a proxy)")
    s.add_argument("--port", type=int, default=8420)
    s.add_argument("--behind-proxy", action="store_true",
                   help="trust X-Forwarded-For from a local reverse proxy")
    s.set_defaults(func=cmd_serve)

    s = sub.add_parser("pair", help="discover units and write config.json (prints the API key location)")
    s.add_argument("--ip", help="skip broadcast, target one unit by IP")
    s.add_argument("--out", help=f"config path (default: $AC_CONFIG = {os.environ['AC_CONFIG']})")
    s.add_argument("--no-prompt", action="store_true", help="don't ask for unit names")
    s.set_defaults(func=cmd_pair)

    s = sub.add_parser("version", help="print version and build commit")
    s.set_defaults(func=cmd_version)
    return p


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    if not getattr(args, "command", None):
        parser.print_help()
        return 2
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
