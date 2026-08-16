"""
`GET /api/system` — the Nerd-screen endpoint.

Two things are being protected here. First, that it answers at all on
whatever platform the suite runs on: nearly every fact it reports is
platform-specific, and the module's whole contract is that an unavailable
fact becomes None rather than a 500. Second — and more importantly — that it
never leaks a credential, because it's the one endpoint that deliberately
returns a broad dump of server state.
"""
from __future__ import annotations

import json
import os

import pytest

from tests.test_auth_v2 import KEY, RefClient, _enroll_v2, _make_app


def _system(client, ref: RefClient):
    headers = {**KEY, **ref.sign_headers("GET", "/api/system", b"")}
    return client.get("/api/system", headers=headers)


def test_system_requires_a_device_credential(tmp_path):
    c = _make_app(tmp_path)
    # API key alone is not enough — same bar as controlling a unit.
    assert c.get("/api/system", headers=KEY).status_code == 401
    assert c.get("/api/system").status_code == 401


def test_system_reports_the_whole_picture(tmp_path):
    c = _make_app(tmp_path)
    ref = RefClient()
    _enroll_v2(c, ref)
    r = _system(c, ref)
    assert r.status_code == 200, r.text
    body = r.json()

    for section in ("server", "os", "init", "cpu", "components", "network",
                    "paths", "settings", "connection", "units", "devices",
                    "programs", "storage", "process"):
        assert section in body, f"missing section: {section}"

    assert body["server"]["name"] == "Breeze Core"
    assert body["server"]["version"]
    assert body["server"]["uptime_seconds"] >= 0
    assert "system_info" in body["server"]["features"]
    # Platform facts: present as keys even where the value can't be determined.
    assert "arch" in body["cpu"] and body["cpu"]["arch"]
    assert "name" in body["init"]
    assert "pretty_name" in body["os"]
    # fastapi must be installed for this test to run at all, so it's a good
    # canary that component detection actually resolves versions.
    assert body["components"]["fastapi"]

    # The enrolled device shows up as a "user", without its credential.
    assert len(body["devices"]) == 1
    dev = body["devices"][0]
    assert dev["auth_version"] == 2 and dev["label"] == "phone"
    assert dev["expired"] is False


def test_system_leaks_no_secrets(tmp_path):
    """The API key, device public keys and V3 unit credentials must not appear
    anywhere in the payload — checked against the raw text, so a secret can't
    hide inside a nested structure this test forgot to walk."""
    c = _make_app(tmp_path)
    ref = RefClient()
    _enroll_v2(c, ref)
    raw = _system(c, ref).text

    assert "test-key-abc" not in raw          # the API key
    assert ref.public_key not in raw          # the device's registered key
    assert "token_hash" not in raw
    assert "public_key" not in raw
    body = json.loads(raw)
    # The unit view exposes only whether V3 credentials exist, never them.
    for unit in body["units"]:
        assert set(unit) >= {"id", "has_v3_credentials"}
        assert "token" not in unit and "key" not in unit


def test_snapshot_survives_a_broken_probe(monkeypatch, tmp_path):
    """A fact that can't be read must degrade to None, not raise: this screen
    failing to load is worse than a blank row on it."""
    from meow_ac import system_info

    monkeypatch.setattr(system_info, "_machine_uptime", lambda: 1 / 0)
    monkeypatch.setattr(system_info.socket, "gethostname",
                        lambda: (_ for _ in ()).throw(OSError("no hostname")))
    system_info.operating_system.cache_clear()

    from meow_ac.settings import Settings
    snap = system_info.snapshot(Settings.from_env(), config_path=tmp_path / "config.json")
    assert snap["machine_uptime_seconds"] is None
    assert snap["os"]["hostname"] is None
    system_info.operating_system.cache_clear()
