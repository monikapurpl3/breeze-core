"""HTTP routers, assembled by the app factory."""

from meow_ac.api.auth import build_auth_router
from meow_ac.api.programs import build_programs_router
from meow_ac.api.units import build_router

__all__ = ["build_router", "build_auth_router", "build_programs_router"]
