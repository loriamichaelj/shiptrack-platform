"""Compare the ledger with the database: report events that were accepted but never persisted.

RDS is private, so this runs on a host inside the VPC. It needs only psycopg, which the release
virtualenv already has; the simulator wheel is installed there with --no-deps.
"""

from __future__ import annotations

from collections.abc import Iterable, Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Protocol

from .ledger import LedgerEntry, read_ledger

CHUNK = 500


class Cursor(Protocol):
    def execute(self, query: str, params: Sequence[Any]) -> Any: ...
    def fetchall(self) -> list[tuple[Any, ...]]: ...


@dataclass(frozen=True)
class VerifyResult:
    accepted: int
    persisted: int
    missing: list[LedgerEntry]

    @property
    def ok(self) -> bool:
        return not self.missing

    def report(self, *, sample: int = 10) -> str:
        lines = [
            f"events accepted in the ledger  {self.accepted}",
            f"events found in the database   {self.persisted}",
            f"accepted but never persisted   {len(self.missing)}",
        ]
        for entry in self.missing[:sample]:
            lines.append(f"  missing: {entry.event_type} {entry.tracking_number} key={entry.idempotency_key}")
        if len(self.missing) > sample:
            lines.append(f"  ... and {len(self.missing) - sample} more")
        return "\n".join(lines)


def chunks(items: Sequence[str], size: int) -> Iterable[Sequence[str]]:
    for start in range(0, len(items), size):
        yield items[start : start + size]


def find_missing(entries: Sequence[LedgerEntry], cursor: Cursor) -> VerifyResult:
    keys = [entry.idempotency_key for entry in entries]
    present: set[str] = set()
    for batch in chunks(keys, CHUNK):
        cursor.execute(
            "SELECT idempotency_key FROM shiptrack.tracking_events WHERE idempotency_key = ANY(%s)",
            (list(batch),),
        )
        present.update(row[0] for row in cursor.fetchall())
    missing = [entry for entry in entries if entry.idempotency_key not in present]
    return VerifyResult(accepted=len(entries), persisted=len(present), missing=missing)


def verify_ledger(ledger_path: Path, db_url: str) -> VerifyResult:
    import psycopg  # imported here so that `run` works without it

    entries = list(read_ledger(ledger_path))
    with psycopg.connect(db_url) as connection, connection.cursor() as cursor:
        return find_missing(entries, cursor)
