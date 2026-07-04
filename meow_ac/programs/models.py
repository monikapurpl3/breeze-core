"""
Program models — the stored shape of favourites, schedules, and curves.

A Program targets one or more units (empty `unit_ids` = all configured
units) and is one of three kinds:

- **favourite** — a named scene (`ControlRequest`), applied on demand via
  `POST /api/programs/{id}/apply`. Not auto-fired.
- **schedule** — a list of day/time triggers, each applying a scene. The
  scheduler fires these when the clock crosses the trigger minute.
- **curve** — a daily time→temperature curve; the scheduler continuously
  sets the interpolated setpoint (plus a base mode/fan, power on).

All times are the server's local time (Europe/Zagreb on the deployed
box). Reuses `ControlRequest` for scene settings so its bounds
(temp 16–30 / 0.5°, known fan speeds) apply to programs too.
"""
from __future__ import annotations

import re
from typing import List, Literal, Optional

from pydantic import BaseModel, Field, field_validator

from meow_ac.devices.schemas import (
    ALLOWED_FAN_SPEEDS,
    OPERATIONAL_MODES,
    ControlRequest,
)

ProgramKind = Literal["favourite", "schedule", "curve"]

_HHMM = re.compile(r"^([01]\d|2[0-3]):([0-5]\d)$")


def _check_time(v: str) -> str:
    if not _HHMM.match(v):
        raise ValueError("time must be 'HH:MM' (24h)")
    return v


class ScheduleEntry(BaseModel):
    # 0=Mon .. 6=Sun; empty list = every day
    days: List[int] = Field(default_factory=list)
    time: str
    settings: ControlRequest

    _vt = field_validator("time")(staticmethod(_check_time))

    @field_validator("days")
    @classmethod
    def _valid_days(cls, v: List[int]) -> List[int]:
        if any(d < 0 or d > 6 for d in v):
            raise ValueError("days must be 0 (Mon) .. 6 (Sun)")
        return sorted(set(v))


class CurvePoint(BaseModel):
    time: str
    temperature: float = Field(ge=16.0, le=30.0)

    _vt = field_validator("time")(staticmethod(_check_time))


class CurveConfig(BaseModel):
    operational_mode: str = "COOL"
    fan_speed: int = 102
    points: List[CurvePoint] = Field(default_factory=list)

    @field_validator("operational_mode")
    @classmethod
    def _valid_mode(cls, v: str) -> str:
        if v.upper() not in OPERATIONAL_MODES:
            raise ValueError(f"operational_mode must be one of {sorted(OPERATIONAL_MODES)}")
        return v.upper()

    @field_validator("fan_speed")
    @classmethod
    def _valid_fan(cls, v: int) -> int:
        if v not in ALLOWED_FAN_SPEEDS:
            raise ValueError(f"fan_speed must be one of {sorted(ALLOWED_FAN_SPEEDS)}")
        return v


class ProgramSpec(BaseModel):
    """The client-supplied shape (POST/PUT body) — no server-assigned id."""

    name: str = Field(min_length=1, max_length=64)
    enabled: bool = True
    unit_ids: List[str] = Field(default_factory=list)
    kind: ProgramKind = "favourite"
    favourite: Optional[ControlRequest] = None
    schedule: List[ScheduleEntry] = Field(default_factory=list)
    curve: Optional[CurveConfig] = None


class Program(ProgramSpec):
    """A stored program (spec + server-assigned id)."""

    id: str


class ProgramsDoc(BaseModel):
    programs: List[Program] = Field(default_factory=list)
