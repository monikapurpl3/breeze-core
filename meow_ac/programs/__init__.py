"""
Programs — favourites, schedules, and time-temperature curves, plus the
background scheduler that fires them.

This is server-side on purpose: schedules and curves must run even when
no client (phone/browser) is connected, so the truth lives here and the
apps are thin managers of it. The scheduler is a single asyncio task in
the uvicorn process (the service runs one worker), started/stopped by
the app's lifespan.
"""

from meow_ac.programs.models import (
    CurveConfig,
    CurvePoint,
    Program,
    ProgramSpec,
    ScheduleEntry,
)
from meow_ac.programs.scheduler import Scheduler
from meow_ac.programs.store import ProgramStore

__all__ = [
    "Program",
    "ProgramSpec",
    "ScheduleEntry",
    "CurvePoint",
    "CurveConfig",
    "ProgramStore",
    "Scheduler",
]
