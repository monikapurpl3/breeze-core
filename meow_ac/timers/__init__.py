"""
One-shot timers — "turn this unit off in 45 minutes".

Deliberately NOT part of programs/. A program is a standing intention that keeps
applying: a schedule fires every Tuesday, a curve drives a setpoint all day. A
timer is the opposite — it exists to happen once and then stop existing. Trying to
express that as a schedule entry means teaching every client that reads programs
about a mode where a schedule is not really a schedule, and leaves a spent one
sitting in the list looking like it will fire again.

So: its own store, its own runner, its own endpoints, and the same seams as
everything else. `timers.json` alongside the other stores, a `TimerRunner` task
started by the app lifespan, a `build_timers_router` factory. Deleting the whole
package would remove the feature and nothing else.
"""
