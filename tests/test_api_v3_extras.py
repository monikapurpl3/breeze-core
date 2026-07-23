"""
Unit tests for the v3.0.0 API extras that don't need live hardware:
serialize_capabilities() (defensive attribute reads + flap-axis derivation)
and the HistoryBuffer ring. The endpoint wiring (whoami / metrics /
history-404) is covered in test_auth_v2.py against the real app.
"""
from __future__ import annotations

import contextlib
from types import SimpleNamespace

import pytest

from meow_ac.devices.history import HistoryBuffer
from meow_ac.devices.schemas import serialize_capabilities
from meow_ac.devices.stream import StateStream


def _m(name):
    return SimpleNamespace(name=name)


class _FakeDevice:
    supported_operation_modes = [_m("COOL"), _m("HEAT")]
    supported_swing_modes = [_m("OFF"), _m("VERTICAL")]  # no horizontal flap
    supported_fan_speeds = [_m("LOW"), _m("HIGH")]
    supports_custom_fan_speed = True
    min_target_temperature = 17.0
    max_target_temperature = 30.0
    supports_eco = False
    supports_eco_mode = True   # OR'd → eco supported
    supports_turbo = True
    # supports_humidity / supports_display_control deliberately absent


def test_capabilities_serialization():
    unit = SimpleNamespace(unit_id="42", name="Bedroom")
    caps = serialize_capabilities(unit, _FakeDevice())
    assert caps["id"] == "42"
    assert caps["operational_modes"] == ["COOL", "HEAT"]
    assert caps["swing_modes"] == ["OFF", "VERTICAL"]
    # derived flap axes: vertical present, horizontal absent
    assert caps["supports_vertical_swing"] is True
    assert caps["supports_horizontal_swing"] is False
    assert caps["supports_eco"] is True          # via supports_eco_mode
    assert caps["supports_turbo"] is True
    assert caps["supports_custom_fan_speed"] is True
    assert caps["min_target_temperature"] == 17.0
    assert caps["max_target_temperature"] == 30.0
    # absent attributes degrade to False, never raise
    assert caps["supports_humidity"] is False
    assert caps["supports_display_control"] is False


def test_capabilities_unknown_swing_is_none():
    # A device that doesn't report swing modes → axes unknown (None), so a
    # client shows all controls rather than hiding them wrongly.
    dev = SimpleNamespace(min_target_temperature=16.0, max_target_temperature=30.0)
    caps = serialize_capabilities(SimpleNamespace(unit_id="1", name="X"), dev)
    assert caps["swing_modes"] is None
    assert caps["supports_vertical_swing"] is None
    assert caps["supports_horizontal_swing"] is None


def test_history_buffer_records_and_bounds():
    buf = HistoryBuffer(size=2)
    for t in (20.0, 21.0, 22.0):
        buf.record({"id": "u1", "target_temperature": t, "online": True})
    samples = buf.samples("u1")
    assert len(samples) == 2                       # ring bounded to 2
    assert samples[-1]["target_temperature"] == 22.0
    assert buf.latest("u1")["target_temperature"] == 22.0
    assert buf.samples("other") == []              # unknown unit → empty


def test_history_buffer_ignores_stateless_record():
    buf = HistoryBuffer(size=4)
    buf.record({"target_temperature": 20.0})       # no id → ignored
    assert buf.latest("anything") is None


# --- SSE broadcaster ---------------------------------------------------------

class _FakeManagerDevice:
    """A device whose state can be mutated between polls."""
    def __init__(self):
        self.online = True
        self.power_state = True
        self.operational_mode = SimpleNamespace(name="COOL")
        self.target_temperature = 22.0
        self.indoor_temperature = 26.0
        self.outdoor_temperature = 31.0
        self.fan_speed = 102
        self.swing_mode = SimpleNamespace(name="OFF")
        self.eco = False
        self.turbo = False

    async def refresh(self):
        pass


class _FakeManager:
    def __init__(self, device):
        self._d = device
        self._u = SimpleNamespace(unit_id="u1", name="Room", ip="192.0.2.5")

    def known_units(self):
        return [self._u]

    def unit_config(self, uid):
        return self._u

    def lock_for(self, uid):
        @contextlib.asynccontextmanager
        async def _noop():
            yield
        return _noop()

    async def get(self, uid):
        return self._d


@pytest.mark.asyncio
async def test_stream_broadcasts_only_on_change():
    dev = _FakeManagerDevice()
    stream = StateStream(_FakeManager(dev), HistoryBuffer(size=10), tick_seconds=1)
    q = stream.subscribe()

    await stream._poll_once()
    assert q.qsize() == 1                     # first observation → an event
    ev_type, data = q.get_nowait()
    assert ev_type == "state" and data["target_temperature"] == 22.0

    await stream._poll_once()
    assert q.qsize() == 0                     # unchanged → no event

    dev.target_temperature = 24.0
    await stream._poll_once()
    assert q.qsize() == 1                     # changed → an event
    assert q.get_nowait()[1]["target_temperature"] == 24.0

    # snapshot reflects the latest broadcast state (for new subscribers)
    snap = stream.snapshot()
    assert snap and snap[0][1]["target_temperature"] == 24.0
