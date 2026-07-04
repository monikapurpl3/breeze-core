"""
A minimal in-memory fixed-window rate limiter for the auth endpoints.

This is a backstop, not the primary defense: on a public deployment the
reverse proxy (nginx `limit_req`) and/or fail2ban should do the heavy
lifting, and they see the real client IPs first. This limiter exists so
brute-forcing the short pairing code is bounded even if someone reaches
the app directly, and so it degrades gracefully with no external state.

Fixed-window (not token-bucket) on purpose: it's a handful of lines, has
no background sweeper, and the window edge-burst it allows is irrelevant
at these limits. Memory is bounded by pruning stale keys on each call.
"""
from __future__ import annotations

import time
from typing import Dict, Tuple


class RateLimiter:
    def __init__(self, max_hits: int, window_seconds: float):
        self.max_hits = max_hits
        self.window = window_seconds
        self._hits: Dict[str, Tuple[int, float]] = {}  # key -> (count, window_start)

    def allow(self, key: str) -> bool:
        """True if this key is under the limit for the current window."""
        now = time.time()
        self._prune(now)
        count, start = self._hits.get(key, (0, now))
        if now - start >= self.window:
            count, start = 0, now  # new window
        count += 1
        self._hits[key] = (count, start)
        return count <= self.max_hits

    def _prune(self, now: float) -> None:
        stale = [k for k, (_, start) in self._hits.items() if now - start >= self.window]
        for k in stale:
            del self._hits[k]
