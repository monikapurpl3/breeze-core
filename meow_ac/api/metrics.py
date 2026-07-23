"""
Prometheus metrics — `GET /metrics`.

Text exposition of last-known unit readings + scheduler counters + build
info, for Grafana/monitoring. Deliberately reads only **cached** values (the
last sample the HistoryBuffer saw); it never triggers a live LAN round-trip,
so a scrape every 15 s can't hammer the AC units. Values appear once a unit
has been polled at least once (by a client or the diag tool).

Gated behind the API key (like /api/version) so a public deployment doesn't
leak unit temperatures — point Prometheus at it with an `X-API-Key` header.
No third-party dependency: the exposition format is small and hand-written.
"""
from __future__ import annotations

from fastapi import APIRouter, Depends, Response

from meow_ac import __version__
from meow_ac.api.meta import _commit
from meow_ac.devices.history import HistoryBuffer
from meow_ac.devices.manager import DeviceManager
from meow_ac.programs.scheduler import Scheduler
from meow_ac.security.base import Authenticator


def _esc(v: str) -> str:
    """Escape a Prometheus label value."""
    return v.replace("\\", "\\\\").replace('"', '\\"').replace("\n", " ")


def build_metrics_router(
    api_key_auth: Authenticator,
    manager: DeviceManager,
    history: HistoryBuffer,
    scheduler: Scheduler,
) -> APIRouter:
    router = APIRouter()

    @router.get("/metrics", dependencies=[Depends(api_key_auth)])
    async def metrics() -> Response:
        lines: list[str] = []

        def metric(name: str, mtype: str, help_: str, rows: list[str]) -> None:
            if not rows:
                return
            lines.append(f"# HELP {name} {help_}")
            lines.append(f"# TYPE {name} {mtype}")
            lines.extend(rows)

        metric("breeze_build_info", "gauge", "Build info (constant 1).",
               [f'breeze_build_info{{version="{_esc(__version__)}",commit="{_esc(_commit())}"}} 1'])

        online, indoor, target, outdoor = [], [], [], []
        for u in manager.known_units():
            lbl = f'unit="{_esc(u.unit_id)}",name="{_esc(u.name)}"'
            s = history.latest(u.unit_id)
            if s is None:
                continue
            if s.get("online") is not None:
                online.append(f"breeze_unit_online{{{lbl}}} {1 if s['online'] else 0}")
            if isinstance(s.get("indoor_temperature"), (int, float)):
                indoor.append(f"breeze_unit_indoor_temperature_celsius{{{lbl}}} {s['indoor_temperature']}")
            if isinstance(s.get("target_temperature"), (int, float)):
                target.append(f"breeze_unit_target_temperature_celsius{{{lbl}}} {s['target_temperature']}")
            if isinstance(s.get("outdoor_temperature"), (int, float)):
                outdoor.append(f"breeze_unit_outdoor_temperature_celsius{{{lbl}}} {s['outdoor_temperature']}")

        metric("breeze_unit_online", "gauge", "1 if the unit was reachable at last poll.", online)
        metric("breeze_unit_indoor_temperature_celsius", "gauge", "Last indoor temperature.", indoor)
        metric("breeze_unit_target_temperature_celsius", "gauge", "Last target temperature.", target)
        metric("breeze_unit_outdoor_temperature_celsius", "gauge", "Last outdoor temperature.", outdoor)

        st = scheduler.status()
        metric("breeze_units_total", "gauge", "Configured units.",
               [f"breeze_units_total {len(manager.known_units())}"])
        metric("breeze_scheduler_runs_total", "counter", "Scheduler tick actions fired.",
               [f"breeze_scheduler_runs_total {int(st.get('runs', 0))}"])
        metric("breeze_scheduler_errors_total", "counter", "Scheduler errors.",
               [f"breeze_scheduler_errors_total {int(st.get('errors', 0))}"])

        return Response(content="\n".join(lines) + "\n", media_type="text/plain; version=0.0.4")

    return router
