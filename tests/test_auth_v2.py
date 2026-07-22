"""
End-to-end auth tests: v1 bearer back-compat, v2 Ed25519 request signing,
replay/skew rejection, the min_auth_version clamp (426), and the in-place
v1→v2 upgrade.

Runs against a real app built by create_app() with a temp config, via
Starlette's TestClient. The v2 client here is the reference implementation of
the wire format the Breeze app reproduces — if you change the canonical
string or headers, change both.

    python -m pytest tests/test_auth_v2.py -q      # needs fastapi, pycryptodome, httpx
"""
from __future__ import annotations

import base64
import json
import os
import time

from Crypto.Hash import SHA3_512
from Crypto.PublicKey import ECC
from Crypto.Signature import eddsa


# --- reference v2 client (mirrors the app's Dart signing) --------------------

def b64u(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode("ascii")


class RefClient:
    """Minimal Ed25519 signing client — the canonical wire reference."""

    def __init__(self):
        self._key = ECC.generate(curve="Ed25519")
        self.public_key = b64u(self._key.public_key().export_key(format="raw"))
        self.key_id = None

    def sign_headers(self, method: str, path: str, body: bytes, *, ts=None, nonce=None):
        ts = str(int(ts if ts is not None else time.time()))
        nonce = nonce or b64u(os.urandom(16))
        body_hash = SHA3_512.new(body).hexdigest()
        canonical = "\n".join(
            ["breeze-auth-v2", method.upper(), path, ts, nonce, body_hash]
        ).encode()
        sig = eddsa.new(self._key, "rfc8032").sign(canonical)
        return {
            "X-Breeze-Auth-Version": "2",
            "X-Breeze-Key-Id": self.key_id or "",
            "X-Breeze-Timestamp": ts,
            "X-Breeze-Nonce": nonce,
            "X-Breeze-Signature": b64u(sig),
        }


# --- harness -----------------------------------------------------------------

def _make_app(tmp_path, min_auth_version=1):
    cfg = tmp_path / "config.json"
    cfg.write_text(json.dumps({"api_key": "test-key-abc", "units": []}))
    os.environ["AC_CONFIG"] = str(cfg)
    os.environ["AC_DEVICES"] = str(tmp_path / "devices.json")
    os.environ["AC_PROGRAMS"] = str(tmp_path / "programs.json")
    os.environ["AC_MIN_AUTH_VERSION"] = str(min_auth_version)
    os.environ["AC_ENROLL_LAN_ONLY"] = "0"  # TestClient peer isn't "LAN"
    # Rebuild settings/app fresh each time.
    from importlib import reload
    import meow_ac.settings as settings_mod
    import meow_ac.app as app_mod
    reload(settings_mod)
    reload(app_mod)
    from starlette.testclient import TestClient
    return TestClient(app_mod.create_app())


KEY = {"X-API-Key": "test-key-abc"}


def _enroll_v2(client, ref: RefClient) -> str:
    r = client.post("/api/auth/enroll/start",
                    headers=KEY, json={"label": "phone", "auth_version": 2,
                                       "public_key": ref.public_key})
    assert r.status_code == 200, r.text
    body = r.json()
    sid, code = body["session_id"], body["user_code"]
    r = client.post("/api/auth/enroll/approve", headers=KEY, json={"code": code})
    assert r.status_code == 200, r.text
    r = client.post("/api/auth/enroll/poll", headers=KEY, json={"session_id": sid})
    j = r.json()
    assert j["status"] == "approved" and j["auth_version"] == 2
    assert "device_token" not in j, "v2 must not return a secret"
    ref.key_id = j["token_id"]
    return j["token_id"]


def _enroll_v1(client) -> str:
    r = client.post("/api/auth/enroll/start", headers=KEY, json={"label": "legacy"})
    sid, code = r.json()["session_id"], r.json()["user_code"]
    client.post("/api/auth/enroll/approve", headers=KEY, json={"code": code})
    j = client.post("/api/auth/enroll/poll", headers=KEY, json={"session_id": sid}).json()
    assert j["auth_version"] == 1 and j["device_token"]
    return j["device_token"]


# --- tests -------------------------------------------------------------------

def test_v2_happy_path_and_signing(tmp_path):
    c = _make_app(tmp_path)
    ref = RefClient()
    _enroll_v2(c, ref)
    h = {**KEY, **ref.sign_headers("GET", "/api/units", b"")}
    r = c.get("/api/units", headers=h)
    assert r.status_code == 200, r.text


def test_v2_rejects_replayed_nonce(tmp_path):
    c = _make_app(tmp_path)
    ref = RefClient()
    _enroll_v2(c, ref)
    h = {**KEY, **ref.sign_headers("GET", "/api/units", b"", nonce="fixed-nonce")}
    assert c.get("/api/units", headers=h).status_code == 200
    # identical signed request again → replay
    assert c.get("/api/units", headers=h).status_code == 401


def test_v2_rejects_stale_timestamp(tmp_path):
    c = _make_app(tmp_path)
    ref = RefClient()
    _enroll_v2(c, ref)
    h = {**KEY, **ref.sign_headers("GET", "/api/units", b"", ts=time.time() - 3600)}
    assert c.get("/api/units", headers=h).status_code == 401


def test_v2_rejects_tampered_path(tmp_path):
    c = _make_app(tmp_path)
    ref = RefClient()
    _enroll_v2(c, ref)
    # sign for /api/units but send to /api/config → signature covers the path
    h = {**KEY, **ref.sign_headers("GET", "/api/units", b"")}
    assert c.get("/api/config", headers=h).status_code == 401


def test_v1_still_works_and_gets_upgrade_hint(tmp_path):
    c = _make_app(tmp_path)
    tok = _enroll_v1(c)
    r = c.get("/api/units", headers={**KEY, "Authorization": f"Bearer {tok}"})
    assert r.status_code == 200
    assert r.headers.get("X-Breeze-Upgrade") == "auth-version=2"


def test_clamp_426_blocks_existing_v1_when_min_is_2(tmp_path):
    # Enrol a v1 device while the floor is 1 (as it is by default)...
    c1 = _make_app(tmp_path, min_auth_version=1)
    tok = _enroll_v1(c1)
    # ...then the admin raises the floor. Same devices.json, reloaded.
    c2 = _make_app(tmp_path, min_auth_version=2)
    r = c2.get("/api/units", headers={**KEY, "Authorization": f"Bearer {tok}"})
    assert r.status_code == 426, r.text
    assert r.json()["detail"]["error"] == "auth_upgrade_required"


def test_clamp_blocks_new_v1_enrollment_but_allows_v2(tmp_path):
    # With the floor at 2, a NEW v1 enrollment is refused up front (no dead
    # bearer credential is minted)...
    c = _make_app(tmp_path, min_auth_version=2)
    r = c.post("/api/auth/enroll/start", headers=KEY, json={"label": "legacy"})
    assert r.status_code == 426, r.text
    assert r.json()["detail"]["error"] == "auth_upgrade_required"
    # ...while v2 enrollment still works.
    ref = RefClient()
    _enroll_v2(c, ref)
    h = {**KEY, **ref.sign_headers("GET", "/api/units", b"")}
    assert c.get("/api/units", headers=h).status_code == 200


def test_in_place_upgrade_v1_to_v2(tmp_path):
    c = _make_app(tmp_path)
    tok = _enroll_v1(c)
    # the device generates a keypair and upgrades using its current token
    ref = RefClient()
    r = c.post("/api/auth/upgrade",
               headers={**KEY, "Authorization": f"Bearer {tok}"},
               json={"public_key": ref.public_key})
    assert r.status_code == 200, r.text
    ref.key_id = r.json()["token_id"]
    assert r.json()["auth_version"] == 2
    # old bearer no longer works...
    assert c.get("/api/units", headers={**KEY, "Authorization": f"Bearer {tok}"}).status_code == 401
    # ...new signature does, under the SAME token_id
    h = {**KEY, **ref.sign_headers("GET", "/api/units", b"")}
    assert c.get("/api/units", headers=h).status_code == 200


def test_v2_device_cannot_downgrade_to_bearer(tmp_path):
    c = _make_app(tmp_path)
    ref = RefClient()
    tid = _enroll_v2(c, ref)
    # try to use the key_id as if it were a bearer token → rejected
    assert c.get("/api/units", headers={**KEY, "Authorization": f"Bearer {tid}"}).status_code == 401


# --- v3.0.0 extras (whoami / metrics / history) ------------------------------

def test_whoami_reports_the_calling_device(tmp_path):
    c = _make_app(tmp_path)
    ref = RefClient()
    tid = _enroll_v2(c, ref)
    h = {**KEY, **ref.sign_headers("GET", "/api/auth/whoami", b"")}
    r = c.get("/api/auth/whoami", headers=h)
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["token_id"] == tid and body["auth_version"] == 2
    assert "label" in body and "expires_at" in body


def test_metrics_endpoint_needs_key_and_reports_build(tmp_path):
    c = _make_app(tmp_path)
    assert c.get("/metrics").status_code == 401           # no key
    r = c.get("/metrics", headers=KEY)
    assert r.status_code == 200
    assert "breeze_build_info" in r.text
    assert "breeze_units_total" in r.text


def test_history_unknown_unit_404(tmp_path):
    c = _make_app(tmp_path)
    ref = RefClient()
    _enroll_v2(c, ref)
    h = {**KEY, **ref.sign_headers("GET", "/api/units/nope/history", b"")}
    assert c.get("/api/units/nope/history", headers=h).status_code == 404
