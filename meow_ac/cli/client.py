"""Shared plumbing for the CLI tools: config/key loading, an HTTP wrapper,
the device-token cache, and self-enrolment (pairing) on the LAN.

The token cache path is deliberately the SAME one `tools/ac-diag.zsh` uses
(`${XDG_CONFIG_HOME:-~/.config}/ac-diag/token`), so the zsh and binary tools
share one enrolled `ac-diag` device instead of minting two.
"""
from __future__ import annotations

import json
import os
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, List, Optional, Tuple

import httpx

DEFAULT_BASE_URL = "http://127.0.0.1:8420"
TOKEN_ENV = "AC_DIAG_TOKEN"


def default_config_path() -> Path:
    return Path(os.environ.get("AC_CONFIG", "/etc/meow-ac/config.json"))


def token_cache_path() -> Path:
    base = os.environ.get("XDG_CONFIG_HOME") or str(Path.home() / ".config")
    return Path(base) / "ac-diag" / "token"


class CliError(SystemExit):
    def __init__(self, message: str):
        print(f"error: {message}")
        super().__init__(1)


def load_config(config_path: Path) -> Tuple[str, List[dict]]:
    """Return (api_key, units) from config.json, with zsh-parity errors."""
    if not config_path.exists():
        raise CliError(f"config not found at {config_path}")
    try:
        raw = config_path.read_text()
    except PermissionError:
        raise CliError(
            f"can't read {config_path} — run with sudo, or join the service group"
        )
    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        raise CliError(f"{config_path} is not valid JSON")
    api_key = data.get("api_key") or ""
    if not api_key:
        raise CliError(f"no api_key in {config_path}")
    return api_key, data.get("units") or []


@dataclass
class Http:
    """Tiny wrapper mirroring the zsh helper: never raises on HTTP errors,
    returns (status, parsed-json-or-text, elapsed_ms); status 0 = unreachable."""

    base_url: str
    api_key: str
    device_token: str = ""
    timeout: float = 15.0
    _client: Optional[httpx.Client] = field(default=None, repr=False)

    def client(self) -> httpx.Client:
        if self._client is None:
            self._client = httpx.Client(timeout=self.timeout)
        return self._client

    def req(self, method: str, endpoint: str, body: Any = None) -> Tuple[int, Any, int]:
        headers = {"X-API-Key": self.api_key}
        if self.device_token:
            headers["Authorization"] = f"Bearer {self.device_token}"
        t0 = time.perf_counter()
        try:
            r = self.client().request(
                method, f"{self.base_url}{endpoint}", headers=headers,
                json=body if body is not None else None,
            )
        except httpx.HTTPError:
            return 0, None, int((time.perf_counter() - t0) * 1000)
        ms = int((time.perf_counter() - t0) * 1000)
        try:
            payload: Any = r.json()
        except ValueError:
            payload = r.text
        return r.status_code, payload, ms

    def close(self) -> None:
        if self._client is not None:
            self._client.close()


# --- device-token cache -------------------------------------------------------

def load_cached_token() -> str:
    env = os.environ.get(TOKEN_ENV, "")
    if env:
        return env.strip()
    p = token_cache_path()
    try:
        return p.read_text().strip()
    except OSError:
        return ""


def save_token(token: str) -> None:
    p = token_cache_path()
    try:
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(token + "\n")
        try:
            p.chmod(0o600)
        except OSError:
            pass
    except OSError:
        pass  # cache is best-effort


def forget_token() -> str:
    p = token_cache_path()
    if p.exists():
        p.unlink()
        return f"removed cached device token: {p}"
    return f"no cached device token at {p}"


# --- self-enrolment (start -> approve -> poll, all key-authenticated) ---------

def pair_device(http: Http, report, label: str = "ac-diag") -> bool:
    """Mint a device token by self-enrolling on the LAN. Mirrors the zsh
    pair_device(); `report` is a Reporter (info/ok/fail). Sets
    http.device_token and caches it on success."""
    report.info(f"self-enrolling as '{label}' to obtain a device token (LAN admin action)...")
    code_, body, _ = http.req("POST", "/api/auth/enroll/start", {"label": label})
    if code_ != 200 or not isinstance(body, dict):
        report.fail(f"enroll/start returned {code_} — cannot pair")
        return False
    sid, ucode = body.get("session_id"), body.get("user_code")
    if not sid or not ucode:
        report.fail("enroll/start returned no session/code")
        return False
    report.info(f"got one-time code {ucode} — approving from this host...")

    code_, body, _ = http.req("POST", "/api/auth/enroll/approve", {"code": ucode})
    if code_ == 403:
        report.fail("approve returned 403 — approval must originate on the LAN; "
                    "run this on the server or a private-network host")
        return False
    if code_ != 200:
        detail = body.get("detail") if isinstance(body, dict) else body
        report.fail(f"approve returned {code_} ({detail})")
        return False

    status = ""
    for _ in range(10):
        code_, body, _ = http.req("POST", "/api/auth/enroll/poll", {"session_id": sid})
        status = body.get("status", "") if isinstance(body, dict) else ""
        if status == "approved":
            token = body.get("device_token", "")
            if token:
                http.device_token = token
                save_token(token)
                report.ok(f"paired — device token acquired (cached at {token_cache_path()}, "
                          f"shows as '{label}' in the devices list)")
                return True
        time.sleep(1)
    report.fail(f"pairing did not complete (last status: {status or 'none'})")
    return False
