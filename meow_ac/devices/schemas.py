"""
The wire schema shared by all three components (API, web UI, CLI).

`ControlRequest` is the POST /control body; `serialize()` produces the
state dict returned by both /state and /control. This shape is the
contract — change it and you change all three clients at once, so keep
edits deliberate.
"""
from __future__ import annotations

from typing import Optional

from pydantic import BaseModel, field_validator
from pydantic import Field

from meow_ac.config.models import UnitConfig

# The fan speeds the units accept: 20/40/60/80/100 + 102 (auto).
ALLOWED_FAN_SPEEDS = {20, 40, 60, 80, 100, 102}

# Enum value names shared across the wire contract (see module docstring).
OPERATIONAL_MODES = {"AUTO", "COOL", "DRY", "HEAT", "FAN_ONLY"}
SWING_MODES = {"OFF", "VERTICAL", "HORIZONTAL", "BOTH"}


class ControlRequest(BaseModel):
    """Body for POST /control. Every field optional — only the ones
    present are applied to the device.

    Numeric fields are bounds-checked here so out-of-range values are
    rejected with a 422 before ever reaching the device, rather than
    being passed through to the AC firmware. The enum fields
    (operational_mode/swing_mode) are validated at apply time against the
    msmart enums (see api/units.py), which is where the 400 comes from.
    """

    power_state: Optional[bool] = None
    operational_mode: Optional[str] = None
    # 16.0–30.0 in 0.5° steps.
    target_temperature: Optional[float] = Field(default=None, ge=16.0, le=30.0)
    fan_speed: Optional[int] = None
    swing_mode: Optional[str] = None
    eco: Optional[bool] = None
    turbo: Optional[bool] = None
    # Whether the unit chirps when it accepts the command. Optional; when
    # absent the apply path defaults to silent (see devices/control.py), so
    # older clients that never send `beep` keep the quiet behaviour.
    beep: Optional[bool] = None

    @field_validator("target_temperature")
    @classmethod
    def _half_degree_steps(cls, v: Optional[float]) -> Optional[float]:
        if v is not None and (v * 2) % 1 != 0:
            raise ValueError("target_temperature must be in 0.5° steps")
        return v

    @field_validator("fan_speed")
    @classmethod
    def _known_fan_speed(cls, v: Optional[int]) -> Optional[int]:
        if v is not None and v not in ALLOWED_FAN_SPEEDS:
            raise ValueError(f"fan_speed must be one of {sorted(ALLOWED_FAN_SPEEDS)}")
        return v


def serialize_capabilities(unit: UnitConfig, device) -> dict:
    """What this unit actually supports, from msmart's get_capabilities()
    (already fetched when the DeviceManager first connects). Lets clients hide
    controls the hardware doesn't have — e.g. a unit with no horizontal flap
    shouldn't offer the left/right swing option.

    Every attribute is read defensively: msmart-ng's capability surface varies
    by version, so a missing attribute becomes a null/false rather than a 500.
    """
    def _names(attr):
        v = getattr(device, attr, None)
        if not v:
            return None
        return [getattr(m, "name", str(m)) for m in v]

    def _any(*attrs) -> bool:
        return any(bool(getattr(device, a, False)) for a in attrs)

    swings = _names("supported_swing_modes")
    swing_set = set(swings) if swings else None

    return {
        "id": unit.unit_id,
        "operational_modes": _names("supported_operation_modes"),
        "swing_modes": swings,
        # Which physical flaps exist — derived from the supported swing modes.
        # None = unknown (older firmware/msmart didn't report it → show all).
        "supports_vertical_swing":
            (("VERTICAL" in swing_set) or ("BOTH" in swing_set)) if swing_set else None,
        "supports_horizontal_swing":
            (("HORIZONTAL" in swing_set) or ("BOTH" in swing_set)) if swing_set else None,
        "fan_speeds": _names("supported_fan_speeds"),
        "supports_custom_fan_speed": _any("supports_custom_fan_speed"),
        "min_target_temperature": getattr(device, "min_target_temperature", 16.0),
        "max_target_temperature": getattr(device, "max_target_temperature", 30.0),
        "supports_eco": _any("supports_eco", "supports_eco_mode"),
        "supports_turbo": _any("supports_turbo", "supports_turbo_mode"),
        "supports_display_control": _any("supports_display_control"),
        "supports_freeze_protection": _any("supports_freeze_protection", "supports_freeze_protection_mode"),
        "supports_humidity": _any("supports_humidity"),
    }


def serialize(unit: UnitConfig, device) -> dict:
    """Build the JSON state object for a unit.

    Enum members are read with `.name`, never `str()`: Python 3.11
    changed `IntEnum.__str__` to format as a plain int, so `str()` here
    would silently emit bare numbers instead of names like "COOL". This
    bit the project once already — keep using `.name`.
    """
    return {
        "id": unit.unit_id,
        "name": unit.name,
        "ip": unit.ip,
        "online": device.online,
        "power_state": device.power_state,
        "operational_mode": device.operational_mode.name,
        "target_temperature": device.target_temperature,
        "indoor_temperature": device.indoor_temperature,
        "outdoor_temperature": device.outdoor_temperature,
        "fan_speed": device.fan_speed,
        "swing_mode": device.swing_mode.name,
        "eco": device.eco,
        "turbo": device.turbo,
    }
