"""Compare the ledger with what was stored: report events that were accepted but never persisted.

Two ways to look. Against the database (`verify_ledger`): the database is private, so this runs on a host
inside the VPC, and it needs only psycopg, which the release virtualenv already has; the simulator wheel is
installed there with --no-deps. Through the API (`verify_ledger_api`): an event the API accepted shows in
the shipment's tracking timeline once a worker has applied it, so a runner with no database access can
check the same thing. An event is identified there by its type and the time it occurred.
"""

from __future__ import annotations

import time
from collections.abc import Callable, Iterable, Sequence
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path
from typing import Any, Protocol

import httpx

from .ledger import LedgerEntry, read_ledger
from .runner import headers_for

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


def _instant(value: str) -> datetime:
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    return parsed if parsed.tzinfo else parsed.replace(tzinfo=UTC)


def find_missing_via_api(entries: Sequence[LedgerEntry], client: httpx.Client) -> list[LedgerEntry]:
    """The entries whose event is not in its shipment's tracking timeline."""
    by_shipment: dict[str, list[LedgerEntry]] = {}
    for entry in entries:
        by_shipment.setdefault(entry.tracking_number, []).append(entry)
    missing: list[LedgerEntry] = []
    for tracking_number, group in by_shipment.items():
        response = client.get(f"/api/v1/track/{tracking_number}")
        if response.status_code == 404:
            stored: set[tuple[str, datetime]] = set()
        else:
            response.raise_for_status()
            stored = {
                (event["event_type"], _instant(event["occurred_at"]))
                for event in response.json().get("events", [])
            }
        missing.extend(e for e in group if (e.event_type, _instant(e.occurred_at)) not in stored)
    return missing


def verify_ledger_api(
    ledger_path: Path,
    base_url: str,
    *,
    target: str = "none",
    token: str = "",
    wait_seconds: float = 0.0,
    poll_seconds: float = 10.0,
    client: httpx.Client | None = None,
    sleep: Callable[[float], None] = time.sleep,
    clock: Callable[[], float] = time.monotonic,
) -> VerifyResult:
    """Check the ledger against the tracking timelines. A worker applies an event after the API accepts
    it, so for `wait_seconds` the events still missing are looked for again every `poll_seconds`."""
    entries = list(read_ledger(ledger_path))
    owned = client is None
    http = client or httpx.Client(
        base_url=base_url,
        headers=headers_for(target, token),
        timeout=httpx.Timeout(30.0),
        follow_redirects=True,
    )
    try:
        deadline = clock() + wait_seconds
        missing = find_missing_via_api(entries, http)
        while missing and clock() < deadline:
            sleep(poll_seconds)
            missing = find_missing_via_api(missing, http)
    finally:
        if owned:
            http.close()
    return VerifyResult(accepted=len(entries), persisted=len(entries) - len(missing), missing=missing)
