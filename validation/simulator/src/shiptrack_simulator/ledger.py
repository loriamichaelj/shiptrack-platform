"""The ledger: one JSON line for every event the API accepted (202), written when it is accepted.

`verify` compares it with the database, so an accepted event that was never stored is visible.
That is how legacy AP-06 (an in-process queue that loses events on restart) is proven.
"""

from __future__ import annotations

import json
from collections.abc import Iterator
from dataclasses import asdict, dataclass
from datetime import UTC, datetime
from pathlib import Path
from typing import TextIO


@dataclass(frozen=True)
class LedgerEntry:
    idempotency_key: str
    shipment_id: str
    tracking_number: str
    event_type: str
    occurred_at: str
    accepted_at: str


def now_iso() -> str:
    return datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%S.%fZ")


class Ledger:
    def __init__(self, path: Path) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        self.path = path
        self._file: TextIO = path.open("a", encoding="utf-8")
        self._seen: set[str] = set()

    def record(self, entry: LedgerEntry) -> bool:
        """Append an entry. A key already recorded (a duplicate send) is written once. Returns True
        when a line was written."""
        if entry.idempotency_key in self._seen:
            return False
        self._seen.add(entry.idempotency_key)
        self._file.write(json.dumps(asdict(entry), separators=(",", ":")) + "\n")
        self._file.flush()
        return True

    def close(self) -> None:
        self._file.close()

    def __enter__(self) -> Ledger:
        return self

    def __exit__(self, *exc: object) -> None:
        self.close()


def read_ledger(path: Path) -> Iterator[LedgerEntry]:
    with path.open(encoding="utf-8") as handle:
        for line in handle:
            if line.strip():
                yield LedgerEntry(**json.loads(line))


def default_ledger_path(results_dir: Path) -> Path:
    return results_dir / f"sent-{datetime.now(UTC).strftime('%Y%m%dT%H%M%SZ')}.jsonl"
