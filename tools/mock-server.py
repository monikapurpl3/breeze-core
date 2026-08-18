#!/usr/bin/env python3
"""Stdlib-only mock of the Breeze Core API, for working on the web UI.

    python tools/mock-server.py            # http://127.0.0.1:8420
    python tools/mock-server.py --port 9000

WHY THIS EXISTS
There is no way to exercise the real server without msmart-ng and live Midea
hardware on the LAN, so UI work otherwise gets verified by reading it. This
serves `static/` and answers just enough of `/api/*` to drive the panel — and,
importantly, it can *push* SSE frames on demand, which is the only practical way
to test the live-state path without a real air conditioner changing state.

It is a development aid and nothing else:

  * every request is treated as authenticated if it carries any X-API-Key, so the
    pairing flow is skipped entirely,
  * the "devices" it reports are invented,
  * it binds 127.0.0.1 only.

Do not point anything real at it, and do not grow it into a second
implementation of the server — when the two disagree, the server is right.
"""
from __future__ import annotations

import argparse
import json
import random
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

STATIC = Path(__file__).resolve().parent.parent / "static"

MODES = ["AUTO", "COOL", "DRY", "HEAT", "FAN_ONLY"]
SWINGS = ["OFF", "VERTICAL", "HORIZONTAL", "BOTH"]

# Mutable so control requests and the SSE ticker can both move the state around.
UNITS = {
    "living-room": {
        "id": "living-room", "name": "Living room", "power": True,
        "operational_mode": "COOL", "target_temperature": 22.0,
        "indoor_temperature": 24.5, "outdoor_temperature": 31.0,
        "fan_speed": 60, "swing_mode": "OFF", "eco_mode": False,
        "turbo_mode": False, "online": True,
    },
    "bedroom": {
        "id": "bedroom", "name": "Bedroom", "power": False,
        "operational_mode": "HEAT", "target_temperature": 20.5,
        "indoor_temperature": 21.0, "outdoor_temperature": 31.0,
        "fan_speed": 102, "swing_mode": "VERTICAL", "eco_mode": True,
        "turbo_mode": False, "online": True,
    },
}

# Every control request lands here so a human can see what the UI actually sent —
# this is how "does the beep flag ride along?" gets answered.
CONTROL_LOG: list[dict] = []

_subscribers: list[list] = []
_lock = threading.Lock()


def publish(unit_id: str) -> None:
    """Queue a state frame for every open stream."""
    payload = json.dumps(UNITS[unit_id])
    with _lock:
        for q in _subscribers:
            q.append(payload)


def drift() -> None:
    """Nudge indoor temperatures so the stream has something to say."""
    while True:
        time.sleep(2.0)
        for uid, u in UNITS.items():
            u["indoor_temperature"] = round(
                max(16.0, min(34.0, u["indoor_temperature"] + random.choice((-0.5, 0.5)))), 1
            )
            publish(uid)


SYSTEM = {
    # Mirrors the section names and nesting of a real /api/system from 3.1.0.
    # Kept faithful on purpose: the first version of this dict invented "host"
    # and "python" sections, the UI was written against them, and the mistake
    # only surfaced when the UI met the real server. A mock that lies is worse
    # than no mock.
    "server": {"name": "Breeze Core", "version": "3.1.0", "commit": "mockmock",
               "python": "3.14.0", "frozen": False,
               "features": ["device_pairing", "programs", "live_stream",
                            "system_info", "beep_control", "unit_history", "metrics"],
               "auth_versions": [1, 2], "min_auth_version": 1},
    "os": {"system": "Linux", "release": "6.1.0", "distro": "Debian 12",
           "hostname": "mock", "machine": "x86_64"},
    "init": {"system": "systemd", "unit": "breeze-core.service"},
    "cpu": {"model": "Intel(R) Core(TM) i5-8300H", "count": 8,
            "load_average": [0.1, 0.2, 0.3]},
    "machine_uptime_seconds": 123456,
    "components": {"msmart-ng": "2026.8.0", "fastapi": "0.141.1",
                   "uvicorn": "0.52.3", "starlette": "1.6.0",
                   "pydantic": "2.13.4", "pydantic-core": "2.46.4",
                   "brotli-asgi": "1.6.0", "cryptography": None},
    "network": {"hostname": "mock", "addresses": ["192.168.1.98", "127.0.0.1"]},
    "paths": {"config": "/etc/breeze-core/config.json",
              "devices": "/etc/breeze-core/devices.json",
              "programs": "/etc/breeze-core/programs.json"},
    "settings": {"docs_enabled": False, "behind_proxy": False,
                 "enrollment_lan_only": True, "token_ttl_days": 3650},
    "connection": {"client_ip": "127.0.0.1", "client_is_private": True,
                   "request_url": "http://127.0.0.1:8420",
                   "host_header": "127.0.0.1:8420", "scheme": "http",
                   "http_version": "1.1", "forwarded_for": None,
                   "behind_proxy_enabled": False, "user_agent": "mock"},
    "process": {"pid": 4242, "rss_bytes": 61 * 1024 ** 2, "threads": 5,
                "uptime_seconds": 900},
    "units": [
        {"id": "living-room", "name": "Living room", "ip": "192.168.1.73",
         "port": 6444, "has_v3_credentials": True, "connected": True,
         "online": True, "samples": 42, "capabilities": None},
    ],
    "devices": [
        {"label": "phone", "token_id": "3f9a1c", "auth_version": 2,
         "created_at": 1767520800.0, "last_used": 1787043120.0,
         "expires_at": 2082758400.0, "revoked": False},
    ],
    "programs": {"favourites": 2, "schedules": 3, "curves": 1},
    "scheduler": {"running": True, "tick_seconds": 30, "last_tick": 1787043120.0},
    "storage": {
        "config": {"path": "/etc/breeze-core/config.json", "exists": True,
                   "size_bytes": 812, "mode": "0640"},
        "devices": {"path": "/etc/breeze-core/devices.json", "exists": True,
                    "size_bytes": 431, "mode": "0600"},
    },
}


class Server(ThreadingHTTPServer):
    # Windows SO_REUSEADDR does not mean what it means on Unix: it lets a second
    # process bind a port that is already in use, after which requests go to
    # whichever server the kernel feels like — in practice the oldest. That cost
    # a genuinely confusing half hour, with an edited mock apparently ignoring
    # its own new code because three copies were bound and an old one was
    # answering. Refuse to start instead.
    allow_reuse_address = False


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    # ---- helpers ----------------------------------------------------------
    def _json(self, obj, status=200):
        body = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _authed(self) -> bool:
        return bool(self.headers.get("X-API-Key"))

    def log_message(self, fmt, *args):   # quieter than the default
        if "/api/" in (args[0] if args else ""):
            super().log_message(fmt, *args)

    # ---- routing ----------------------------------------------------------
    def do_GET(self):
        path = self.path.split("?")[0]

        if path.startswith("/api/"):
            if not self._authed():
                return self._json({"detail": "missing key"}, 401)
            if path == "/api/version":
                return self._json({"name": "Breeze Core", "version": "3.1.0",
                                   "commit": "mockmock"})
            if path == "/api/meta":
                return self._json({"features": SYSTEM["server"]["features"],
                                   "auth_versions": [1, 2], "min_auth_version": 1})
            if path == "/api/system":
                return self._json(SYSTEM)
            if path == "/api/units":
                return self._json([{"id": u["id"], "name": u["name"]}
                                   for u in UNITS.values()])
            if path == "/api/units/state":
                return self._json({"states": list(UNITS.values()), "errors": []})
            if path == "/api/units/stream":
                return self._stream()
            if path.startswith("/api/units/") and path.endswith("/state"):
                uid = path.split("/")[3]
                if uid in UNITS:
                    return self._json(UNITS[uid])
                return self._json({"detail": "unknown unit"}, 404)
            return self._json({"detail": "not found in mock"}, 404)

        return self._static(path)

    def do_POST(self):
        path = self.path.split("?")[0]
        if not self._authed():
            return self._json({"detail": "missing key"}, 401)
        length = int(self.headers.get("Content-Length") or 0)
        body = json.loads(self.rfile.read(length) or b"{}")
        if path.startswith("/api/units/") and path.endswith("/control"):
            uid = path.split("/")[3]
            if uid not in UNITS:
                return self._json({"detail": "unknown unit"}, 404)
            CONTROL_LOG.append({"unit": uid, "body": body})
            # flush: stdout is block-buffered when redirected to a file, and a
            # dev server whose log only appears at exit is no use at all.
            print("  CONTROL %s <- %s" % (uid, json.dumps(body, sort_keys=True)),
                  flush=True)
            for k, v in body.items():
                if k == "beep":
                    continue          # the real server applies it and forgets it
                if k in UNITS[uid]:
                    UNITS[uid][k] = v
            publish(uid)
            # Echo the received body back as _received. The real server does not
            # do this and must not: it exists so UI work can assert what the
            # browser actually sent (does the beep flag ride along? does a
            # temperature arrive as a number rather than a string?) without
            # depending on server logs, which on Windows get mangled when a
            # redirected stdout is shared between a killed process and its
            # replacement.
            return self._json(dict(UNITS[uid], _received=body))
        return self._json({"detail": "not found in mock"}, 404)

    # ---- SSE --------------------------------------------------------------
    def _stream(self):
        q: list = []
        with _lock:
            _subscribers.append(q)
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "keep-alive")
        # No Content-Length: this response never ends. Chunked is off because the
        # UI reads the raw byte stream, and HTTP/1.1 without a length means
        # "read until close", which is what SSE wants.
        self.end_headers()
        try:
            last_keepalive = time.time()
            while True:
                if q:
                    payload = q.pop(0)
                    frame = "event: state\ndata: %s\n\n" % payload
                    self.wfile.write(frame.encode())
                    self.wfile.flush()
                elif time.time() - last_keepalive > 5:
                    self.wfile.write(b": keepalive\n\n")
                    self.wfile.flush()
                    last_keepalive = time.time()
                else:
                    time.sleep(0.05)
        except (BrokenPipeError, ConnectionAbortedError, ConnectionResetError):
            pass
        finally:
            with _lock:
                if q in _subscribers:
                    _subscribers.remove(q)

    # ---- static -----------------------------------------------------------
    def _static(self, path):
        rel = "index.html" if path in ("/", "") else path.lstrip("/")
        target = (STATIC / rel).resolve()
        if not str(target).startswith(str(STATIC)) or not target.is_file():
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        # The real server registers these MIME types at startup because Windows
        # serves .js as text/plain, which browsers refuse for ES modules. Same
        # reason here, or nothing loads.
        kind = {".html": "text/html", ".js": "text/javascript",
                ".css": "text/css", ".svg": "image/svg+xml",
                ".png": "image/png", ".ico": "image/x-icon"}.get(target.suffix,
                                                                 "application/octet-stream")
        data = target.read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", kind + ("; charset=utf-8" if kind.startswith("text") else ""))
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8420)
    args = ap.parse_args()
    threading.Thread(target=drift, daemon=True).start()
    srv = Server(("127.0.0.1", args.port), Handler)
    print("mock Breeze Core on http://127.0.0.1:%d (any X-API-Key is accepted)" % args.port,
          flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
