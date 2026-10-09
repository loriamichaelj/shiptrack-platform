from collections.abc import Sequence
from typing import Any

from shiptrack_simulator.ledger import LedgerEntry
from shiptrack_simulator.verify import CHUNK, find_missing


def entry(key: str) -> LedgerEntry:
    return LedgerEntry(
        idempotency_key=key,
        shipment_id="s",
        tracking_number="MF0000000001",
        event_type="DELIVERED",
        occurred_at="2026-10-09T10:00:00Z",
        accepted_at="2026-10-09T10:00:01.000000Z",
    )


class FakeCursor:
    """Stands in for a psycopg cursor over a table that holds `stored` keys."""

    def __init__(self, stored: set[str]) -> None:
        self.stored = stored
        self.queries = 0
        self._rows: list[tuple[Any, ...]] = []

    def execute(self, query: str, params: Sequence[Any]) -> None:
        assert "shiptrack.tracking_events" in query
        self.queries += 1
        self._rows = [(key,) for key in params[0] if key in self.stored]

    def fetchall(self) -> list[tuple[Any, ...]]:
        return self._rows


def test_nothing_is_missing_when_every_key_is_stored() -> None:
    result = find_missing([entry("a"), entry("b")], FakeCursor({"a", "b"}))
    assert result.ok
    assert (result.accepted, result.persisted, result.missing) == (2, 2, [])


def test_accepted_but_unstored_events_are_reported() -> None:
    result = find_missing([entry("a"), entry("b"), entry("c")], FakeCursor({"a"}))
    assert not result.ok
    assert [e.idempotency_key for e in result.missing] == ["b", "c"]
    assert "accepted but never persisted   2" in result.report()


def test_large_ledgers_are_checked_in_chunks() -> None:
    entries = [entry(f"k{i}") for i in range(CHUNK * 2 + 1)]
    cursor = FakeCursor({e.idempotency_key for e in entries})
    result = find_missing(entries, cursor)
    assert result.ok
    assert cursor.queries == 3


def test_the_report_names_what_is_missing_without_flooding() -> None:
    entries = [entry(f"k{i}") for i in range(30)]
    report = find_missing(entries, FakeCursor(set())).report(sample=3)
    assert report.count("missing:") == 3
    assert "and 27 more" in report
