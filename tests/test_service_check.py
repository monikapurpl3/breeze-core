"""
Unit tests for the diag background-service detection (meow_ac.cli.service).

The service tools (systemctl/rc-service/sc/…) aren't present or meaningful in
a test container, so we drive the parsers directly with canned command output
via a patched `service._run`. This verifies the running / boot-enabled
interpretation without needing a live init system.
"""
from __future__ import annotations

import pytest

from meow_ac.cli import service


@pytest.fixture(autouse=True)
def _restore_run():
    original = service._run
    yield
    service._run = original


def _patch(mapping):
    """Patch service._run to return (rc, stdout, stderr) by substring match."""
    def fake(cmd, timeout=5):
        joined = " ".join(cmd)
        for needle, result in mapping.items():
            if needle in joined:
                return result
        return (1, "", "")
    service._run = fake


def test_systemd_running_and_enabled():
    _patch({
        "list-unit-files": (0, "breeze-core.service enabled", ""),
        "is-active": (0, "active", ""),
        "is-enabled": (0, "enabled", ""),
    })
    st = service._systemd(["breeze-core", "meow-ac"])
    assert st.found and st.name == "breeze-core"
    assert st.running is True and st.boot is True


def test_systemd_stopped_and_disabled():
    _patch({
        "list-unit-files": (0, "meow-ac.service disabled", ""),
        "is-active": (3, "inactive", ""),
        "is-enabled": (1, "disabled", ""),
    })
    st = service._systemd(["breeze-core", "meow-ac"])
    assert st.found and st.running is False and st.boot is False


def test_systemd_not_installed():
    _patch({"list-unit-files": (0, "", "")})
    st = service._systemd(["breeze-core", "meow-ac"])
    assert not st.found


def test_windows_running_autostart():
    _patch({
        "query": (0, "SERVICE_NAME: BreezeCore\n  STATE : 4  RUNNING", ""),
        "qc": (0, "START_TYPE : 2   AUTO_START", ""),
    })
    st = service._windows(["BreezeCore", "breeze-core"])
    assert st.found and st.running is True and st.boot is True


def test_windows_not_installed():
    _patch({"query": (1060, "", "[SC] OpenService FAILED 1060")})
    st = service._windows(["BreezeCore", "breeze-core"])
    assert not st.found
