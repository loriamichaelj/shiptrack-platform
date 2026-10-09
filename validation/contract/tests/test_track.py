import httpx
import pytest

from support import TRACK_EVENT_KEYS, TRACK_VIEW_KEYS, assert_error, parse_iso, post_event, wait_for_status
from datetime import datetime, timedelta


def test_tracking_an_unknown_number_is_404(client: httpx.Client) -> None:
    assert_error(client.get("/api/v1/track/MF0000000000"), 404, "NOT_FOUND")


@pytest.mark.smoke
def test_track_view_is_public_and_has_no_internal_ids(client: httpx.Client, shipment: dict) -> None:
    response = client.get(f"/api/v1/track/{shipment['tracking_number']}")
    assert response.status_code == 200
    body = response.json()
    assert set(body) == TRACK_VIEW_KEYS
    assert body["tracking_number"] == shipment["tracking_number"]
    assert body["carrier_code"] == shipment["carrier_code"]
    assert body["status"] == "CREATED"
    assert body["events"] == []


def test_track_events_are_applied_only_and_sorted_by_time(
    client: httpx.Client, shipment: dict, base_time: datetime
) -> None:
    number = shipment["tracking_number"]
    for step, event_type in enumerate(["PICKED_UP", "IN_TRANSIT", "OUT_FOR_DELIVERY"]):
        assert post_event(client, shipment["id"], event_type, base_time + timedelta(minutes=step)).status_code == 202
        wait_for_status(client, number, event_type)
    events = client.get(f"/api/v1/track/{number}").json()["events"]
    assert [e["event_type"] for e in events] == ["PICKED_UP", "IN_TRANSIT", "OUT_FOR_DELIVERY"]
    assert all(set(e) == TRACK_EVENT_KEYS for e in events)
    times = [parse_iso(e["occurred_at"]) for e in events]
    assert times == sorted(times)
