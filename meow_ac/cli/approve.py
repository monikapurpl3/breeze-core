"""`breeze-core approve / devices / revoke` — port of tools/ac-approve.zsh.

Approval and device management are admin actions the server restricts to the
local network, so run these ON the server (or another LAN host), pointed at
the LAN URL.
"""
from __future__ import annotations

from datetime import datetime

from .client import CliError, Http


def _fmt_ts(value) -> str:
    try:
        return datetime.fromtimestamp(float(value)).strftime("%Y-%m-%d %H:%M")
    except (TypeError, ValueError):
        return str(value)


def do_approve(http: Http, code: str, config_path) -> int:
    if not code:
        raise CliError("no code given")
    status, body, _ = http.req("POST", "/api/auth/enroll/approve", {"code": code})
    if status == 200 and isinstance(body, dict):
        print(f'approved: "{body.get("label")}" (token_id {body.get("token_id")}). '
              "The device now has its token.")
        return 0
    if status == 400:
        print("rejected: invalid or expired code (they expire fast — get a fresh one)")
        return 1
    if status == 403:
        print("rejected: this host isn't on the trusted LAN (approval is LAN-only)")
        return 1
    if status == 401:
        raise CliError(f"the API key in {config_path} was rejected (401)")
    if status == 0:
        raise CliError(f"couldn't reach {http.base_url} — is the server running, and is the URL right?")
    raise CliError(f"unexpected response ({status}): {body}")


def do_list(http: Http) -> int:
    status, body, _ = http.req("GET", "/api/auth/devices")
    if status != 200 or not isinstance(body, list):
        raise CliError(f"list failed ({status}): {body}")
    if not body:
        print("no devices enrolled yet.")
        return 0
    print(f"enrolled devices ({len(body)}):")
    for d in body:
        used = f"last used {_fmt_ts(d['last_used'])}" if d.get("last_used") else "never used"
        print(f"  {d.get('token_id')}  {d.get('label')}  "
              f"(enrolled {_fmt_ts(d.get('created_at'))})  {used}")
    return 0


def do_revoke(http: Http, token_id: str) -> int:
    if not token_id:
        raise CliError("no token_id given")
    status, body, _ = http.req("DELETE", f"/api/auth/devices/{token_id}")
    if status == 204:
        print(f"revoked {token_id} — that device can no longer control the units.")
        return 0
    if status == 404:
        print(f"no device with token_id {token_id} (try: devices)")
        return 1
    if status == 403:
        raise CliError("this host isn't on the trusted LAN (management is LAN-only)")
    if status == 401:
        raise CliError("the API key was rejected (401)")
    raise CliError(f"unexpected response ({status}): {body}")
