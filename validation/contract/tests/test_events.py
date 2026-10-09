"""Event ingestion: POST /api/v1/shipments/{id}/events answers 202 before the event is applied, so
the tests poll the public track view. Events that must be ignored are checked after a short settle."""

from __future__ import annotations

import uuid
from datetime import datetime, timedelta

import httpx
import pytest

from support import (
    assert_error,
    iso,
    parse_iso,
    post_event,
    settle,
    track,
    wait_for,
    wait_for_status,
)


def test_event_requires_an_idempotency_key(client: httpx.Client, shipment: dict, base_time: datetime) -> None:
    response = client.post(
        f"/api/v1/shipments/{shipment['id']}/events",
        json={"event_type": "PICKED_UP", "location": "Depot", "occurred_at": iso(base_time)},
    )
    assert_error(response, 400, "MISSING_IDEMPOTENCY_KEY")


def test_event_for_an_unknown_shipment_is_404(client: httpx.Client, base_time: datetime) -> None:
    assert_error(post_event(client, str(uuid.uuid4()), "PICKED_UP", base_time), 404, "NOT_FOUND")


def test_event_with_an_unknown_type_is_a_validation_error(
    client: httpx.Client, shipment: dict, base_time: datetime
) -> None:
    assert_error(post_event(client, shipment["id"], "TELEPORTED", base_time), 422, "VALIDATION_ERROR")


def test_idempotency_key_longer_than_64_characters_is_rejected(
    client: httpx.Client, shipment: dict, base_time: datetime
) -> None:
    response = post_event(client, shipment["id"], "PICKED_UP", base_time, key="k" * 65)
    assert_error(response, 422, "VALIDATION_ERROR")


@pytest.mark.smoke
def test_event_is_accepted_then_applied(client: httpx.Client, shipment: dict, base_time: datetime) -> None:
    key = f"contract-{uuid.uuid4().hex}"
    response = post_event(client, shipment["id"], "PICKED_UP", base_time, key=key, location="Leeds depot")
    assert response.status_code == 202
    assert response.json() == {"accepted": True, "idempotency_key": key}

    view = wait_for_status(client, shipment["tracking_number"], "PICKED_UP")
    assert view["events"] == [{"event_type": "PICKED_UP", "location": "Leeds depot", "occurred_at": iso(base_time)}]
    assert parse_iso(view["estimated_delivery_at"]) == base_time + timedelta(hours=72)


def test_a_duplicate_idempotency_key_is_applied_once(
    client: httpx.Client, shipment: dict, base_time: datetime
) -> None:
    key = f"contract-{uuid.uuid4().hex}"
    assert post_event(client, shipment["id"], "PICKED_UP", base_time, key=key).status_code == 202
    wait_for_status(client, shipment["tracking_number"], "PICKED_UP")
    assert post_event(client, shipment["id"], "PICKED_UP", base_time, key=key).status_code == 202
    settle()
    assert len(track(client, shipment["tracking_number"])["events"]) == 1


def test_estimated_delivery_follows_the_eta_rules(
    client: httpx.Client, shipment: dict, base_time: datetime
) -> None:
    number = shipment["tracking_number"]
    expectations = [
        ("PICKED_UP", timedelta(hours=72)),
        ("IN_TRANSIT", timedelta(hours=48)),
        ("OUT_FOR_DELIVERY", timedelta(hours=8)),
    ]
    for step, (event_type, offset) in enumerate(expectations):
        occurred = base_time + timedelta(minutes=step)
        assert post_event(client, shipment["id"], event_type, occurred).status_code == 202
        view = wait_for_status(client, number, event_type)
        assert parse_iso(view["estimated_delivery_at"]) == occurred + offset, event_type

    delivered = base_time + timedelta(minutes=10)
    assert post_event(client, shipment["id"], "DELIVERED", delivered).status_code == 202
    view = wait_for_status(client, number, "DELIVERED")
    assert parse_iso(view["delivered_at"]) == delivered
    assert parse_iso(view["estimated_delivery_at"]) == delivered


def test_a_forward_skip_is_allowed(client: httpx.Client, shipment: dict, base_time: datetime) -> None:
    assert post_event(client, shipment["id"], "IN_TRANSIT", base_time).status_code == 202
    wait_for_status(client, shipment["tracking_number"], "IN_TRANSIT")


def test_an_out_of_order_event_is_not_applied(client: httpx.Client, shipment: dict, base_time: datetime) -> None:
    number = shipment["tracking_number"]
    assert post_event(client, shipment["id"], "IN_TRANSIT", base_time + timedelta(minutes=5)).status_code == 202
    wait_for_status(client, number, "IN_TRANSIT")
    # Earlier than the last applied event, although the status would be a valid step forward.
    assert post_event(client, shipment["id"], "OUT_FOR_DELIVERY", base_time).status_code == 202
    settle()
    view = track(client, number)
    assert view["status"] == "IN_TRANSIT"
    assert [e["event_type"] for e in view["events"]] == ["IN_TRANSIT"]


def test_a_backward_transition_is_not_applied(client: httpx.Client, shipment: dict, base_time: datetime) -> None:
    number = shipment["tracking_number"]
    assert post_event(client, shipment["id"], "IN_TRANSIT", base_time).status_code == 202
    wait_for_status(client, number, "IN_TRANSIT")
    assert post_event(client, shipment["id"], "PICKED_UP", base_time + timedelta(minutes=1)).status_code == 202
    settle()
    view = track(client, number)
    assert view["status"] == "IN_TRANSIT"
    assert [e["event_type"] for e in view["events"]] == ["IN_TRANSIT"]


def test_an_exception_adds_a_day_and_can_resume(client: httpx.Client, shipment: dict, base_time: datetime) -> None:
    number = shipment["tracking_number"]
    transit_at = base_time
    assert post_event(client, shipment["id"], "IN_TRANSIT", transit_at).status_code == 202
    wait_for_status(client, number, "IN_TRANSIT")

    assert post_event(client, shipment["id"], "EXCEPTION", transit_at + timedelta(minutes=1)).status_code == 202
    view = wait_for_status(client, number, "EXCEPTION")
    assert parse_iso(view["estimated_delivery_at"]) == transit_at + timedelta(hours=48) + timedelta(hours=24)

    resumed_at = transit_at + timedelta(minutes=2)
    assert post_event(client, shipment["id"], "IN_TRANSIT", resumed_at).status_code == 202
    view = wait_for_status(client, number, "IN_TRANSIT")
    assert parse_iso(view["estimated_delivery_at"]) == resumed_at + timedelta(hours=48)


def test_delivered_is_terminal(client: httpx.Client, shipment: dict, base_time: datetime) -> None:
    number = shipment["tracking_number"]
    assert post_event(client, shipment["id"], "DELIVERED", base_time).status_code == 202
    wait_for_status(client, number, "DELIVERED")
    assert post_event(client, shipment["id"], "EXCEPTION", base_time + timedelta(minutes=1)).status_code == 202
    settle()
    assert track(client, number)["status"] == "DELIVERED"


def test_the_shipment_resource_reflects_applied_events(
    client: httpx.Client, shipment: dict, base_time: datetime
) -> None:
    assert post_event(client, shipment["id"], "PICKED_UP", base_time).status_code == 202
    wait_for(
        lambda: client.get(f"/api/v1/shipments/{shipment['id']}").json()["status"] == "PICKED_UP",
        what="the shipment resource to show PICKED_UP",
    )
