from pathlib import Path

from shiptrack_simulator.ledger import Ledger, LedgerEntry, read_ledger


def entry(key: str) -> LedgerEntry:
    return LedgerEntry(
        idempotency_key=key,
        shipment_id="00000000-0000-0000-0000-00000000000a",
        tracking_number="MF0000000001",
        event_type="PICKED_UP",
        occurred_at="2026-10-09T10:00:00Z",
        accepted_at="2026-10-09T10:00:01.000000Z",
    )


def test_entries_round_trip(tmp_path: Path) -> None:
    path = tmp_path / "sent.jsonl"
    with Ledger(path) as ledger:
        assert ledger.record(entry("a"))
        assert ledger.record(entry("b"))
    assert [e.idempotency_key for e in read_ledger(path)] == ["a", "b"]


def test_a_duplicate_key_is_written_once(tmp_path: Path) -> None:
    path = tmp_path / "sent.jsonl"
    with Ledger(path) as ledger:
        assert ledger.record(entry("a"))
        assert not ledger.record(entry("a"))
    assert len(list(read_ledger(path))) == 1


def test_each_line_is_flushed_when_written(tmp_path: Path) -> None:
    path = tmp_path / "sent.jsonl"
    ledger = Ledger(path)
    ledger.record(entry("a"))
    assert len(list(read_ledger(path))) == 1  # readable before close, so a crash loses nothing
    ledger.close()


def test_the_results_directory_is_created(tmp_path: Path) -> None:
    path = tmp_path / "nested" / "results" / "sent.jsonl"
    with Ledger(path) as ledger:
        ledger.record(entry("a"))
    assert path.exists()
