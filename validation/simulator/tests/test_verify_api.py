"""verify through the API: the ledger against the tracking timelines, with httpx.MockTransport."""

import json
from pathlib import Path

import httpx

from shiptrack_simulator.ledger import LedgerEntry
from shiptrack_simulator.verify import find_missing_via_api, verify_ledger_api


def entry(
    key: str, event_type: str = "PICKED_UP", at: str = "2026-10-09T10:00:00Z", tn: str = "MF0000000001"
):
    return LedgerEntry(
        idempotency_key=key,
        shipment_id="s",
        tracking_number=tn,
        event_type=event_type,
        occurred_at=at,
        accepted_at="2026-10-09T10:00:01.000000Z",
    )


def timeline(*events: tuple[str, str]) -> dict:
    return {
        "tracking_number": "x",
        "events": [{"event_type": t, "location": "Hub", "occurred_at": at} for t, at in events],
    }


def client(timelines: dict[str, dict | None]) -> httpx.Client:
    def handler(request: httpx.Request) -> httpx.Response:
        tn = request.url.path.rsplit("/", 1)[-1]
        body = timelines.get(tn)
        return httpx.Response(404) if body is None else httpx.Response(200, json=body)

    return httpx.Client(base_url="http://api.test", transport=httpx.MockTransport(handler))


def test_a_stored_event_is_found_whatever_the_timestamp_spelling() -> None:
    api = client({"MF0000000001": timeline(("PICKED_UP", "2026-10-09T10:00:00+00:00"))})
    assert find_missing_via_api([entry("a")], api) == []


def test_an_event_missing_from_the_timeline_is_reported() -> None:
    api = client({"MF0000000001": timeline(("PICKED_UP", "2026-10-09T10:00:00Z"))})
    missing = find_missing_via_api([entry("a"), entry("b", "DELIVERED", "2026-10-09T12:00:00Z")], api)
    assert [e.idempotency_key for e in missing] == ["b"]


def test_an_unknown_shipment_means_every_event_is_missing() -> None:
    assert len(find_missing_via_api([entry("a"), entry("b", "DELIVERED")], client({}))) == 2


def write(path: Path, entries: list[LedgerEntry]) -> Path:
    path.write_text("".join(json.dumps(e.__dict__) + "\n" for e in entries))
    return path


def test_the_wait_looks_again_until_a_worker_has_applied_the_event(tmp_path: Path) -> None:
    ledger = write(tmp_path / "sent.jsonl", [entry("a"), entry("b", "DELIVERED", "2026-10-09T12:00:00Z")])
    calls = {"n": 0}

    def handler(request: httpx.Request) -> httpx.Response:
        calls["n"] += 1
        events = [("PICKED_UP", "2026-10-09T10:00:00Z")]
        if calls["n"] > 2:  # the worker catches up after the second look
            events.append(("DELIVERED", "2026-10-09T12:00:00Z"))
        return httpx.Response(200, json=timeline(*events))

    api = httpx.Client(base_url="http://api.test", transport=httpx.MockTransport(handler))
    now = {"t": 0.0}
    result = verify_ledger_api(
        ledger,
        "http://api.test",
        wait_seconds=60,
        poll_seconds=10,
        client=api,
        sleep=lambda s: now.__setitem__("t", now["t"] + s),
        clock=lambda: now["t"],
    )
    assert result.ok
    assert (result.accepted, result.persisted) == (2, 2)


def test_an_event_that_never_arrives_is_reported_after_the_wait(tmp_path: Path) -> None:
    ledger = write(tmp_path / "sent.jsonl", [entry("a")])
    api = client({"MF0000000001": timeline()})
    now = {"t": 0.0}
    result = verify_ledger_api(
        ledger,
        "http://api.test",
        wait_seconds=30,
        poll_seconds=10,
        client=api,
        sleep=lambda s: now.__setitem__("t", now["t"] + s),
        clock=lambda: now["t"],
    )
    assert not result.ok
    assert now["t"] >= 30
    assert "accepted but never persisted   1" in result.report()
