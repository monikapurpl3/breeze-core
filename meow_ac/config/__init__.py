"""Typed access to config.json — the source of truth for the service."""

from meow_ac.config.models import (
    AppConfig,
    DeviceRecord,
    DevicesDoc,
    UnitConfig,
)
from meow_ac.config.store import ConfigStore

__all__ = ["AppConfig", "UnitConfig", "DeviceRecord", "DevicesDoc", "ConfigStore"]
