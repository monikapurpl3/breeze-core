"""
Tests for the v3.0.0 additions: the LAN port-scan discovery helper and the
optional `beep` control field.

The scan test stands up a real listening TCP socket on a loopback port in the
Midea range and scans a tiny loopback subnet, so it exercises the actual
asyncio connect path without needing hardware or a whole subnet.

    python -m pytest tests/test_scan_and_beep.py -q
"""
from __future__ import annotations

import asyncio
import socket

import pytest

from meow_ac.devices import discovery
from meow_ac.devices.schemas import ControlRequest


# --- scan --------------------------------------------------------------------

@pytest.mark.asyncio
async def test_scan_finds_a_listening_midea_port():
    # Listen on 127.0.0.1:6444 (in the Midea range).
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", 6444))
    srv.listen(8)
    srv.setblocking(False)
    try:
        # 127.0.0.0/29 → hosts .1..6; .1 is our listener.
        found = await discovery.scan_subnet("127.0.0.0/29", timeout=0.5)
        assert found.get("127.0.0.1") == 6444
    finally:
        srv.close()


@pytest.mark.asyncio
async def test_scan_refuses_public_subnet():
    with pytest.raises(ValueError):
        await discovery.scan_subnet("8.8.8.0/30")


@pytest.mark.asyncio
async def test_scan_refuses_oversized_subnet():
    with pytest.raises(ValueError):
        await discovery.scan_subnet("10.0.0.0/8")


@pytest.mark.asyncio
async def test_scan_empty_subnet_finds_nothing():
    # .128/30 of loopback: nothing listens there.
    found = await discovery.scan_subnet("127.0.0.128/30", timeout=0.3)
    assert found == {}


# --- beep --------------------------------------------------------------------

def test_beep_field_optional_and_bool():
    assert ControlRequest().beep is None
    assert ControlRequest(beep=True).beep is True
    assert ControlRequest(beep=False).beep is False
