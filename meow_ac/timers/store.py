"""
TimerStore — persistence for one-shot timers.

Same shape as ProgramStore and TokenStore: a JSON file next to the others,
app-written, mode 600, loaded once and held in memory, rewritten on mutation.

Unlike the other stores this one is expected to be **empty most of the time** —
entries delete themselves when they fire. A timers.json full of past entries means
the runner is not running, which is worth knowing at a glance.
"""
from __future__ import annotations

import logging
import secrets
from pathlib import Path
from typing import List, Optional

from pydantic import ValidationError

from meow_ac.timers.models import Timer, TimerRequest, TimersDoc, build_timer

log = logging.getLogger("meow-ac")


class TimerStore:
    def __init__(self, path: Path):
        self.path = Path(path)
        self._doc: Optional[TimersDoc] = None

    def load(self) -> TimersDoc:
        if not self.path.exists():
            self._doc = TimersDoc()
            return self._doc
        try:
            self._doc = TimersDoc.model_validate_json(self.path.read_text())
        except (ValidationError, ValueError):
            log.warning("timers file %s unreadable — starting with none", self.path)
            self._doc = TimersDoc()
        return self._doc

    @property
    def doc(self) -> TimersDoc:
        if self._doc is None:
            self.load()
        assert self._doc is not None
        return self._doc

    def save(self) -> None:
        try:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            self.path.write_text(self.doc.model_dump_json(indent=2))
            self.path.chmod(0o600)
        except PermissionError as e:
            log.error(
                "cannot write %s (%s) — is its directory owned/writable by "
                "the service user? e.g. `chown -R meow-ac:meow-ac %s`",
                self.path, e, self.path.parent,
            )
            raise

    def list(self) -> List[Timer]:
        return list(self.doc.timers)

    def get(self, timer_id: str) -> Optional[Timer]:
        for t in self.doc.timers:
            if t.id == timer_id:
                return t
        return None

    def for_unit(self, unit_id: str) -> List[Timer]:
        return [t for t in self.doc.timers if unit_id in t.unit_ids]

    def add(self, req: TimerRequest) -> Timer:
        timer = build_timer(secrets.token_hex(6), req)
        self.doc.timers.append(timer)
        try:
            self.save()
        except Exception:
            # Roll the in-memory list back, or the API would report a timer that
            # will vanish on the next restart.
            self.doc.timers.pop()
            raise
        return timer

    def delete(self, timer_id: str) -> bool:
        before = len(self.doc.timers)
        self.doc.timers = [t for t in self.doc.timers if t.id != timer_id]
        if len(self.doc.timers) == before:
            return False
        self.save()
        return True

    def delete_many(self, timer_ids: List[str]) -> int:
        """Used by the runner after firing a batch: one write, not one per timer."""
        doomed = set(timer_ids)
        before = len(self.doc.timers)
        self.doc.timers = [t for t in self.doc.timers if t.id not in doomed]
        removed = before - len(self.doc.timers)
        if removed:
            self.save()
        return removed
