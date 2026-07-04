"""
ProgramStore — persistence for programs (favourites/schedules/curves).

Same pattern as TokenStore: a JSON file in /etc/meow-ac, app-written,
mode 600, loaded once and held in memory, rewritten on mutation. Kept
separate from config.json (admin) and devices.json (tokens).
"""
from __future__ import annotations

import logging
import secrets
from pathlib import Path
from typing import List, Optional

from pydantic import ValidationError

from meow_ac.programs.models import Program, ProgramSpec, ProgramsDoc

log = logging.getLogger("meow-ac")


class ProgramStore:
    def __init__(self, path: Path):
        self.path = Path(path)
        self._doc: Optional[ProgramsDoc] = None

    def load(self) -> ProgramsDoc:
        if not self.path.exists():
            self._doc = ProgramsDoc()
            return self._doc
        try:
            self._doc = ProgramsDoc.model_validate_json(self.path.read_text())
        except (ValidationError, ValueError):
            log.warning("programs file %s unreadable — starting with none", self.path)
            self._doc = ProgramsDoc()
        return self._doc

    @property
    def doc(self) -> ProgramsDoc:
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

    def list(self) -> List[Program]:
        return list(self.doc.programs)

    def get(self, program_id: str) -> Optional[Program]:
        for p in self.doc.programs:
            if p.id == program_id:
                return p
        return None

    def add(self, spec: ProgramSpec) -> Program:
        program = Program(id=secrets.token_hex(6), **spec.model_dump())
        self.doc.programs.append(program)
        try:
            self.save()
        except Exception:
            self.doc.programs.pop()
            raise
        return program

    def update(self, program_id: str, spec: ProgramSpec) -> Optional[Program]:
        for i, p in enumerate(self.doc.programs):
            if p.id == program_id:
                updated = Program(id=program_id, **spec.model_dump())
                previous = self.doc.programs[i]
                self.doc.programs[i] = updated
                try:
                    self.save()
                except Exception:
                    self.doc.programs[i] = previous
                    raise
                return updated
        return None

    def delete(self, program_id: str) -> bool:
        before = len(self.doc.programs)
        self.doc.programs = [p for p in self.doc.programs if p.id != program_id]
        if len(self.doc.programs) == before:
            return False
        self.save()
        return True
