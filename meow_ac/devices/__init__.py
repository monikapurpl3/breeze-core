"""Device connection lifecycle, discovery, and state (de)serialization."""

from meow_ac.devices.manager import DeviceManager
from meow_ac.devices.schemas import ControlRequest, serialize

__all__ = ["DeviceManager", "ControlRequest", "serialize"]
