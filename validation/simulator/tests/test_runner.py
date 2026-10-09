"""Run the simulator against a fake API served by httpx.MockTransport."""

import asyncio
import json
from datetime import UTC, datetime
from pathlib import Path

import httpx

from shiptrack_simulator.ledger import Ledger, read_ledger
from shiptrack_simulator.plan import plan_run
from shiptrack_simulator.runner import run

NOW = datetime(2026, 10, 9, 12, 0, 0, tzinfo=UTC)


class FakeApi:
    def __init__(self, *, reject_events: bool = False) -> None:
        self.reject_events = reject_events
        self.requests: list[httpx.Request] = []
        self.shipments = 0
        self.pods = 0

    def __call__(self, request: httpx.Request) -> httpx.Response:
        self.requests.append(request)
        path = request.url.path
        if request.method == "POST" and path == "/api/v1/shipments":
            self.shipments += 1
            return httpx.Response(
                201, json={"id": f"id-{self.shipments}", "tracking_number": f"MF{self.shipments:010d}"}
            )
        if path.endswith("/events"):
            if self.reject_events:
                return httpx.Response(503, json={"error": {"code": "INTERNAL"}})
            return httpx.Response(202, json={"accepted": True})
        if path.endswith("/pod"):
            self.pods += 1
            return httpx.Response(201, json={})
        return httpx.Response(404)


def go(tmp_path: Path, api: FakeApi, shipments: int = 30, **kwargs):  # type: ignore[no-untyped-def]
    plans = plan_run(11, shipments, NOW)
    with Ledger(tmp_path / "sent.jsonl") as ledger:
        stats = asyncio.run(
            run(
                plans,
                base_url="http://api.test",
                target=kwargs.pop("target", "legacy"),
                token="secret",
                ledger=ledger,
                transport=httpx.MockTransport(api),
                **kwargs,
            )
        )
    return plans, stats


def test_every_accepted_event_is_in_the_ledger_once(tmp_path: Path) -> None:
    api = FakeApi()
    plans, stats = go(tmp_path, api)
    entries = list(read_ledger(tmp_path / "sent.jsonl"))
    unique_events = sum(1 for p in plans for e in p.events if not e.duplicate)
    assert len(entries) == unique_events
    assert len({e.idempotency_key for e in entries}) == len(entries)
    assert stats.events_accepted >= unique_events  # duplicates were accepted too


def test_events_that_were_not_accepted_are_not_in_the_ledger(tmp_path: Path) -> None:
    api = FakeApi(reject_events=True)
    _, stats = go(tmp_path, api)
    assert list(read_ledger(tmp_path / "sent.jsonl")) == []
    assert stats.events_rejected > 0 and stats.events_accepted == 0


def test_duplicates_reuse_the_idempotency_key(tmp_path: Path) -> None:
    api = FakeApi()
    plans, stats = go(tmp_path, api, shipments=300)
    keys = [r.headers["Idempotency-Key"] for r in api.requests if r.url.path.endswith("/events")]
    assert len(keys) - len(set(keys)) == stats.duplicates_sent > 0


def test_each_delivered_shipment_gets_one_pod_and_it_is_never_read_back(tmp_path: Path) -> None:
    api = FakeApi()
    plans, stats = go(tmp_path, api)
    assert api.pods == stats.pods_uploaded == sum(p.delivers for p in plans)
    assert not [r for r in api.requests if r.method == "GET"]


def test_routing_headers_are_sent_when_a_target_is_set(tmp_path: Path) -> None:
    api = FakeApi()
    go(tmp_path, api, shipments=3)
    assert {r.headers["X-ShipTrack-Target"] for r in api.requests} == {"legacy"}
    assert {r.headers["X-ShipTrack-Test-Token"] for r in api.requests} == {"secret"}


def test_no_routing_headers_without_a_target(tmp_path: Path) -> None:
    api = FakeApi()
    go(tmp_path, api, shipments=3, target="none")
    assert all("X-ShipTrack-Target" not in r.headers for r in api.requests)


def test_event_bodies_match_the_api(tmp_path: Path) -> None:
    api = FakeApi()
    go(tmp_path, api, shipments=2)
    body = json.loads(next(r for r in api.requests if r.url.path.endswith("/events")).content)
    assert set(body) == {"event_type", "location", "occurred_at"}
    assert body["occurred_at"].endswith("Z")
