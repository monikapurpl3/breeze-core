"""
Wire models for one-shot timers.

THE ONE DESIGN DECISION WORTH KNOWING: a client asks for **minutes**, never for a
wall-clock time, and the server computes the moment from its own clock.

The alternative — the client sending "fire at 23:15" — puts the burden of knowing
the server's timezone on every client. The phone is not necessarily in the same
zone as the server (a flat at home, a phone abroad), its own clock may be adrift
(which this project has already been bitten by, see the 3.0.2 auth work), and the
scheduler works in naive server-local time. "In 45 minutes" is unambiguous
everywhere and needs no shared understanding of anything.
"""
from __future__ import annotations

from datetime import datetime, timedelta
from typing import List, Optional

from pydantic import BaseModel, Field

from meow_ac.devices.schemas import ControlRequest

# A day is the ceiling on purpose: this is "I am going to sleep / I am leaving the
# house", not a scheduling system. Anything longer is a program.
MAX_MINUTES = 24 * 60


def _power_off() -> ControlRequest:
    return ControlRequest(power_state=False)


class TimerRequest(BaseModel):
    """What a client posts. `settings` defaults to turning the unit off, which is
    what a sleep timer is for — but the field exists, so the same mechanism can
    later mean "switch to eco in an hour" without a second feature."""

    unit_ids: List[str] = Field(default_factory=list, max_length=64)
    minutes: int = Field(ge=1, le=MAX_MINUTES)
    settings: Optional[ControlRequest] = None
    label: str = Field(default="", max_length=64)


class Timer(BaseModel):
    id: str
    unit_ids: List[str] = Field(default_factory=list)
    minutes: int
    # Both stored as naive server-local ISO strings, the same clock the scheduler
    # works in. A client that wants a countdown should use `seconds_remaining`
    # rather than parsing these against its own clock.
    created_at: str
    fires_at: str
    settings: ControlRequest
    label: str = ""

    def seconds_remaining(self, now: Optional[datetime] = None) -> int:
        """Whole seconds until this fires, floored at zero.

        Computed server-side and sent to clients precisely so a phone with a
        drifting clock still counts down correctly.
        """
        now = now or datetime.now()
        try:
            due = datetime.fromisoformat(self.fires_at)
        except ValueError:
            return 0
        return max(0, int((due - now).total_seconds()))

    def is_due(self, now: Optional[datetime] = None) -> bool:
        return self.seconds_remaining(now) == 0


def build_timer(timer_id: str, req: TimerRequest, now: Optional[datetime] = None) -> Timer:
    now = now or datetime.now()
    return Timer(
        id=timer_id,
        unit_ids=list(req.unit_ids),
        minutes=req.minutes,
        created_at=now.isoformat(timespec="seconds"),
        fires_at=(now + timedelta(minutes=req.minutes)).isoformat(timespec="seconds"),
        settings=req.settings or _power_off(),
        label=req.label,
    )


class TimersDoc(BaseModel):
    timers: List[Timer] = Field(default_factory=list)
