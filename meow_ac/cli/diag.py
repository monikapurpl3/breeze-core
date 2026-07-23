"""`breeze-core diag` — port of tools/ac-diag.zsh (same checks, same output
style). Pure HTTP; reads config.json only for the API key and the expected
unit list.

The battery: config sanity → background service (running? enabled at boot?) →
connectivity → server version/build/features →
auth posture → control-API authorization (self-pairing on the LAN if needed)
→ paired devices w/ expiry warnings → unit-listing parity → config
secret-sanitisation → batch state → input validation → per-unit
state/latency/enum checks (+ optional control round-trip) → programs/scheduler
→ summary. Exit code 0 = no failures.
"""
from __future__ import annotations

import time
from datetime import datetime
from pathlib import Path

from . import service
from .client import (
    Http, forget_token, load_cached_token, load_config, pair_device,
)

MODES = {"AUTO", "COOL", "DRY", "HEAT", "FAN_ONLY"}
SWINGS = {"OFF", "VERTICAL", "HORIZONTAL", "BOTH"}


class Reporter:
    """Plain, timestamped output — identical shape to the zsh tool."""

    def __init__(self) -> None:
        self.warns = 0
        self.fails = 0

    @staticmethod
    def _ts() -> str:
        return datetime.now().strftime("[%H:%M:%S]")

    def section(self, title: str) -> None:
        print(f"\n{self._ts()} == {title} ==")

    def info(self, msg: str) -> None:
        print(f"{self._ts()}   {msg}")

    def ok(self, msg: str) -> None:
        print(f"{self._ts()}   OK      {msg}")

    def warn(self, msg: str) -> None:
        self.warns += 1
        print(f"{self._ts()}   WARN    {msg}")

    def fail(self, msg: str) -> None:
        self.fails += 1
        print(f"{self._ts()}   FAIL    {msg}")


class Diag:
    def __init__(self, http: Http, config_path: Path, units: list, r: Reporter):
        self.http = http
        self.config_path = config_path
        self.units = units  # [{id,name,ip}, ...] from config.json
        self.r = r
        self.version = ""
        self.commit = ""
        self.features: set = set()
        self.unit_auth_ok = False
        self.key_only = False

    # -- battery pieces --------------------------------------------------

    def check_config(self, api_key: str) -> None:
        r = self.r
        r.section("config")
        r.info(f"path: {self.config_path}")
        r.ok("config file is readable")
        r.ok("config is valid JSON")
        r.ok(f"api_key present ({len(api_key)} characters)")
        if not self.units:
            r.fail("config has zero units")
            raise SystemExit(1)
        r.ok(f"found {len(self.units)} unit(s) in config")

    def check_service(self, extra_name=None) -> None:
        """Host-local: is the breeze-core background service running, and is
        it enabled to start at boot? Only meaningful when diag runs on the
        server itself — skipped gracefully otherwise."""
        r = self.r
        r.section("background service")
        st = service.detect(extra_name)
        if st.manager == "none":
            r.info("no init/service manager recognised on this host — skipping "
                   "(this check applies when diag runs on the server itself)")
            return
        if not st.found:
            r.info(f"{st.manager} present, but no breeze-core/meow-ac service is "
                   "installed here — skipping (run diag on the server host to check it)")
            return

        detail = f" [{st.detail}]" if st.detail else ""
        if st.running is True:
            r.ok(f"service '{st.name}' is running ({st.manager}){detail}")
        elif st.running is False:
            r.fail(f"service '{st.name}' is installed but NOT running ({st.manager}) — "
                   f"start it{detail}")
        else:
            r.warn(f"couldn't determine whether '{st.name}' is running ({st.manager}){detail}")

        if st.boot is True:
            r.ok(f"service '{st.name}' is enabled to start at boot")
        elif st.boot is False:
            r.warn(f"service '{st.name}' is NOT enabled at boot — it won't come back "
                   "after a reboot")
        else:
            r.info(f"couldn't determine the boot-start setting for '{st.name}' ({st.manager})")

    def check_connectivity(self) -> None:
        r = self.r
        r.section("connectivity")
        r.info(f"base url: {self.http.base_url}")
        status, _, ms = self.http.req("GET", "/api/health")
        if status == 0:
            status, _, ms = self.http.req("GET", "/api/units")  # pre-2.4 servers
        if status == 0:
            r.fail(f"could not reach {self.http.base_url} at all — is the service running?")
            raise SystemExit(1)
        r.ok(f"server is reachable (http {status} in {ms} ms)")

    def check_version(self) -> None:
        r = self.r
        r.section("server version & build")
        status, body, _ = self.http.req("GET", "/api/health")
        if status == 200 and isinstance(body, dict):
            r.ok(f"/api/health OK (status={body.get('status', '?')})")
        else:
            r.warn(f"/api/health returned {status} (server may predate 2.4.0)")
        status, body, _ = self.http.req("GET", "/api/version")
        if status != 200 or not isinstance(body, dict):
            r.warn(f"/api/version returned {status} — cannot read build info (server < 2.4.0?)")
            return
        self.version = str(body.get("version", "?"))
        self.commit = str(body.get("commit", "unknown"))
        self.features = set(body.get("features") or [])
        r.ok(f"Breeze Core {self.version} (commit {self.commit}); "
             f"server sees {body.get('units', '?')} unit(s)")
        r.info(f"features: {' '.join(sorted(self.features)) or 'none advertised'}")

    def check_auth(self) -> None:
        r = self.r
        r.section("authentication")
        saved_key, saved_tok = self.http.api_key, self.http.device_token

        self.http.api_key, self.http.device_token = "", ""
        status, _, _ = self.http.req("GET", "/api/units")
        (r.ok if status == 401 else r.fail)(
            f"request with no key {'correctly rejected (401)' if status == 401 else f'returned {status}, expected 401'}")

        self.http.api_key = "definitely-not-the-real-key"
        status, _, _ = self.http.req("GET", "/api/units")
        (r.ok if status == 401 else r.fail)(
            f"request with wrong key {'correctly rejected (401)' if status == 401 else f'returned {status}, expected 401'}")

        self.http.api_key, self.http.device_token = saved_key, ""
        status, _, _ = self.http.req("GET", "/api/units")
        if status == 200:
            r.ok("API key alone is accepted (200) — control API is not token-gated")
        elif status == 401:
            r.ok("API key alone is rejected (401) — a device token is also required (hardened; good)")
        else:
            r.warn(f"API key alone returned {status} (expected 200 or 401)")
        self.http.device_token = saved_tok

    def ensure_unit_auth(self, pair: bool, no_pair: bool) -> None:
        r = self.r
        r.section("control-api authorization")
        if pair:
            self.http.device_token = ""
            forget_token()
            r.info("--pair given: discarding any cached token and re-enrolling")

        saved = self.http.device_token
        self.http.device_token = ""
        status, _, _ = self.http.req("GET", "/api/units")
        self.http.device_token = saved
        if status == 200:
            self.key_only = self.unit_auth_ok = True
            r.warn("server accepts the API key WITHOUT a device token — "
                   "control API is not token-gated (older/loosened build)")
            return

        if self.http.device_token:
            status, _, _ = self.http.req("GET", "/api/units")
            if status == 200:
                r.ok("device token accepted — control API reachable")
                self.unit_auth_ok = True
                return
            r.warn(f"the provided/cached device token was rejected ({status}) — "
                   "discarding and re-pairing")
            self.http.device_token = ""

        if no_pair:
            r.warn("no device token and --no-pair set — skipping unit / config / programs checks")
            return

        if pair_device(self.http, r):
            status, _, _ = self.http.req("GET", "/api/units")
            if status == 200:
                r.ok("control API reachable with the freshly-minted token")
                self.unit_auth_ok = True
                return
            r.warn(f"still cannot reach /api/units after pairing ({status})")
        r.warn("no working device token — token-gated checks will be skipped")

    def check_devices(self) -> None:
        r = self.r
        r.section("paired devices")
        status, body, _ = self.http.req("GET", "/api/auth/devices")
        if status in (401, 403):
            r.warn(f"/api/auth/devices needs the API key from the LAN — got {status} (running off-LAN?)")
            return
        if status == 404:
            r.info("device-management endpoint not present")
            return
        if status != 200 or not isinstance(body, list):
            r.warn(f"/api/auth/devices returned {status}")
            return
        r.ok(f"{len(body)} device token(s) enrolled")
        now = time.time()

        def _ts(v):
            try:
                return datetime.fromtimestamp(float(v)).strftime("%Y-%m-%d %H:%M")
            except (TypeError, ValueError):
                return str(v)

        for d in body:
            label = d.get("label", "?")
            last = _ts(d["last_used"]) if d.get("last_used") else "never"
            exp = d.get("expires_at")
            if exp is None:
                r.info(f"  {label} — no expiry (last used {last})")
            elif isinstance(exp, (int, float)):
                if exp < now:
                    r.warn(f"  {label} — token EXPIRED — revoke it: breeze-core revoke <id>")
                elif exp < now + 7 * 86400:
                    r.warn(f"  {label} — token expires within 7 days")
                else:
                    r.info(f"  {label} — valid (last used {last})")
            else:
                r.info(f"  {label} — expires {exp} (last used {last})")

    def check_units_listing(self) -> None:
        r = self.r
        r.section("unit listing")
        status, body, _ = self.http.req("GET", "/api/units")
        if status != 200 or not isinstance(body, list):
            r.fail(f"GET /api/units returned {status}")
            return
        if len(body) == len(self.units):
            r.ok(f"API reports {len(body)} unit(s), matches config")
        else:
            r.fail(f"API reports {len(body)} unit(s), config has {len(self.units)} — "
                   "service may need a restart")

    def check_config_security(self) -> None:
        r = self.r
        r.section("config API (secret sanitisation)")
        if self.features and "config_api" not in self.features:
            r.info("server doesn't advertise config_api — skipping")
            return
        status, body, _ = self.http.req("GET", "/api/config")
        if status == 401:
            r.warn("/api/config needs key+token but none was accepted — skipping (try --pair)")
            return
        if status == 404:
            r.info("/api/config not present (server < 2.2.0) — skipping")
            return
        if status != 200:
            r.warn(f"/api/config returned {status}")
            return

        def leaks(obj) -> int:
            n = 0
            if isinstance(obj, dict):
                for k, v in obj.items():
                    kl = k.lower()
                    secretish = "api_key" in kl or "token" in kl or kl == "key" or kl.endswith("_key")
                    if secretish and v not in (None, False, ""):
                        n += 1
                    n += leaks(v)
            elif isinstance(obj, list):
                n += sum(leaks(x) for x in obj)
            return n

        n = leaks(body)
        (r.ok if n == 0 else r.fail)(
            "/api/config exposes no api_key/token/key values (sanitised)" if n == 0
            else f"/api/config exposes {n} secret-looking value(s) — possible leak")
        import json as _json
        if self.http.api_key in _json.dumps(body):
            r.fail("/api/config body contains the API key verbatim — leak")
        else:
            r.ok("the API key does not appear anywhere in the /api/config body")

    def check_batch_state(self) -> None:
        r = self.r
        r.section("batch state")
        if self.features and "batch_state" not in self.features:
            r.info("server doesn't advertise batch_state — skipping")
            return
        status, body, ms = self.http.req("GET", "/api/units/state")
        if status != 200 or not isinstance(body, dict):
            r.fail(f"GET /api/units/state returned {status}")
            return
        states, errors = body.get("states") or [], body.get("errors") or []
        r.ok(f"batch returned {len(states)} state(s) in one request ({ms} ms)")
        if errors:
            names = " ".join(str(e.get("id") or e.get("unit_id") or "?") for e in errors)
            r.warn(f"batch reports {len(errors)} unreachable unit(s): {names}")
        else:
            r.ok("no per-unit errors in the batch response")
        seen = len(states) + len(errors)
        (r.ok if seen == len(self.units) else r.warn)(
            f"batch covers all {len(self.units)} configured unit(s)" if seen == len(self.units)
            else f"batch covered {seen} unit(s); config has {len(self.units)}")

    def check_bounds(self) -> None:
        r = self.r
        r.section("input validation")
        if not self.units:
            r.info("no units to test against")
            return
        status, _, _ = self.http.req("GET", "/api/units/nonexistent-unit-id/state")
        (r.ok if status == 404 else r.warn)(
            "unknown unit id correctly returns 404" if status == 404
            else f"unknown unit id returned {status} (expected 404)")
        uid = self.units[0]["id"]
        status, _, _ = self.http.req("POST", f"/api/units/{uid}/control",
                                     {"target_temperature": 99})
        if status == 422:
            r.ok("out-of-range target_temperature rejected with 422 "
                 "(bounds enforced before touching the unit)")
        elif status == 400:
            r.ok("out-of-range target_temperature rejected with 400")
        elif 200 <= status < 300:
            r.fail(f"out-of-range target_temperature was ACCEPTED ({status}) — "
                   "server-side bounds not enforced")
        else:
            r.warn(f"out-of-range control returned {status} (expected 422)")

    def diagnose_unit(self, unit: dict, control_test: bool, interactive: bool) -> None:
        r = self.r
        uid, name, ip = unit["id"], unit.get("name", "?"), unit.get("ip", "?")
        r.section(f"unit: {name}  (id={uid}, ip={ip})")

        status, s, ms = self.http.req("GET", f"/api/units/{uid}/state")
        if status != 200 or not isinstance(s, dict):
            r.fail(f"GET state returned {status} — unit unreachable or misconfigured")
            return
        r.ok(f"state fetched (http 200, {ms} ms)")

        online, target = s.get("online"), s.get("target_temperature")
        mode, swing = s.get("operational_mode"), s.get("swing_mode")
        r.info(f"online={online} power={s.get('power_state')} mode={mode} target={target}C")
        r.info(f"indoor={s.get('indoor_temperature')}C outdoor={s.get('outdoor_temperature')}C "
               f"fan={s.get('fan_speed')} swing={swing} eco={s.get('eco')} turbo={s.get('turbo')}")

        (r.ok if online else r.warn)("unit reports online" if online else "unit reports offline")
        if isinstance(target, (int, float)) and 16 <= target <= 30:
            r.ok(f"target_temperature ({target}) within expected 16-30 range")
        else:
            r.warn(f"target_temperature ({target}) looks out of range")
        if s.get("indoor_temperature") is None:
            r.warn("indoor_temperature is null — sensor reading unavailable")
        else:
            r.ok(f"indoor_temperature reading present ({s['indoor_temperature']} C)")
        (r.ok if mode in MODES else r.warn)(
            f"operational_mode ({mode}) is a recognised value" if mode in MODES
            else f"operational_mode ({mode}) is not one of the documented values")
        (r.ok if swing in SWINGS else r.warn)(
            f"swing_mode ({swing}) is a recognised value" if swing in SWINGS
            else f"swing_mode ({swing}) is not one of the documented values")

        r.info("running 5x state fetches to check round-trip latency...")
        samples = []
        for _ in range(5):
            status, _, ms = self.http.req("GET", f"/api/units/{uid}/state")
            if status == 200:
                samples.append(ms)
        if samples:
            avg = sum(samples) // len(samples)
            r.info(f"samples (ms): {' '.join(map(str, samples))}   avg: {avg} ms")
            if avg < 500:
                r.ok(f"average round-trip is {avg} ms — normal for a LAN device")
            else:
                r.warn(f"average round-trip is {avg} ms — slower than expected, "
                       "check WiFi signal to this unit")
        else:
            r.fail("none of the 5 repeat requests succeeded")

        run_control = control_test
        if interactive and not control_test:
            print("  Run a live control round-trip test on this unit? It re-sends its")
            print("  current target_temperature unchanged — it will NOT change how the unit is running.")
            run_control = input("  [y/N] ").strip().lower() in ("y", "yes")
        if run_control:
            if not online:
                r.warn("skipping control test — unit reports offline")
            else:
                r.info(f"sending control request with unchanged target_temperature={target} ...")
                status, echoed, ms = self.http.req(
                    "POST", f"/api/units/{uid}/control", {"target_temperature": target})
                if status != 200 or not isinstance(echoed, dict):
                    r.fail(f"control request returned {status}")
                elif echoed.get("target_temperature") == target:
                    r.ok(f"control round-trip confirmed ({ms} ms) — API can command this unit")
                else:
                    r.warn(f"control accepted but target_temperature came back as "
                           f"{echoed.get('target_temperature')}, expected {target}")
        else:
            r.info("control round-trip test skipped")

    def check_programs(self) -> None:
        r = self.r
        r.section("programs / scheduler")
        if self.features and "programs" not in self.features:
            r.info("server doesn't advertise programs — skipping")
            return
        status, body, _ = self.http.req("GET", "/api/programs/status")
        if status == 200:
            r.ok(f"scheduler status: {body}")
        elif status == 401:
            r.warn("/api/programs/status needs key+token — skipping (no token)")
        else:
            r.warn(f"/api/programs/status returned {status}")
        status, body, _ = self.http.req("GET", "/api/programs")
        if status == 200 and isinstance(body, list):
            kinds = {"favourite": 0, "schedule": 0, "curve": 0}
            for p in body:
                kinds[p.get("kind", "")] = kinds.get(p.get("kind", ""), 0) + 1
            enabled = sum(1 for p in body if p.get("enabled"))
            r.ok(f"{len(body)} program(s): {kinds['favourite']} favourite, "
                 f"{kinds['schedule']} schedule, {kinds['curve']} curve ({enabled} enabled)")

    def summary(self) -> int:
        r = self.r
        r.section("summary")
        r.info(f"warnings: {r.warns}   failures: {r.fails}")
        if r.fails:
            r.info("result: PROBLEMS FOUND")
        elif r.warns:
            r.info("result: OK, WITH WARNINGS")
        else:
            r.info("result: ALL CHECKS PASSED")
        return 1 if r.fails else 0


def find_unit(units: list, selector: str):
    for u in units:
        if str(u.get("id")) == selector:
            return u
    for u in units:
        if str(u.get("name", "")).lower() == selector.lower():
            return u
    return None


def run(args) -> int:
    """Entry point for `breeze-core diag` (args from the launcher parser)."""
    if args.forget_token:
        print(forget_token())
        return 0

    config_path = Path(args.config)
    api_key, units = load_config(config_path)
    http = Http(base_url=args.base_url, api_key=api_key,
                device_token=args.token or load_cached_token())
    r = Reporter()
    d = Diag(http, config_path, units, r)

    d.check_config(api_key)
    # Local service check first — if the server is unreachable below, knowing
    # the service isn't running (or isn't enabled at boot) is the answer.
    d.check_service(getattr(args, "service_name", None))
    d.check_connectivity()
    d.check_version()
    d.check_auth()
    d.ensure_unit_auth(pair=args.pair, no_pair=args.no_pair)
    d.check_devices()

    interactive = not (args.auto or args.unit)
    if d.unit_auth_ok:
        d.check_units_listing()
        d.check_config_security()
        d.check_batch_state()
        d.check_bounds()
        if args.unit:
            u = find_unit(units, args.unit)
            if u is None:
                r.fail(f"no unit matches --unit '{args.unit}' (give an id or an exact name)")
            else:
                d.diagnose_unit(u, args.with_control_test, interactive=False)
        else:
            for u in units:
                d.diagnose_unit(u, args.with_control_test, interactive=interactive)
        d.check_programs()
    else:
        d.check_config_security()
        r.section("token-gated checks")
        r.warn("skipped unit listing / batch / bounds / programs — no control-API access (see above)")

    rc = d.summary()
    http.close()
    return rc
