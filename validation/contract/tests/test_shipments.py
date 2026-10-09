import uuid

import httpx
import pytest

from support import ISO_UTC, SHIPMENT_KEYS, TRACKING_NUMBER, Settings, assert_error, create_shipment, new_shipment_body


@pytest.mark.smoke
def test_create_shipment(client: httpx.Client, settings: Settings) -> None:
    response = client.post("/api/v1/shipments", json=new_shipment_body(settings))
    assert response.status_code == 201
    body = response.json()
    assert set(body) == SHIPMENT_KEYS
    assert TRACKING_NUMBER.match(body["tracking_number"]), body["tracking_number"]
    assert body["carrier_code"] == settings.carrier_code
    assert body["status"] == "CREATED"
    assert body["sla_breached"] is False
    assert body["estimated_delivery_at"] is None
    assert body["delivered_at"] is None
    for field in ("promised_delivery_at", "created_at", "updated_at"):
        assert ISO_UTC.match(body[field]), f"{field} must be ISO-8601 UTC with a Z suffix: {body[field]}"
    assert response.headers["location"].endswith(f"/api/v1/shipments/{body['id']}")


def test_get_shipment_returns_what_was_created(client: httpx.Client, shipment: dict) -> None:
    response = client.get(f"/api/v1/shipments/{shipment['id']}")
    assert response.status_code == 200
    assert response.json() == shipment


def test_tracking_numbers_are_unique(client: httpx.Client, settings: Settings) -> None:
    numbers = {create_shipment(client, settings)["tracking_number"] for _ in range(3)}
    assert len(numbers) == 3


def test_get_unknown_shipment_is_404(client: httpx.Client) -> None:
    assert_error(client.get(f"/api/v1/shipments/{uuid.uuid4()}"), 404, "NOT_FOUND")


def test_create_with_missing_fields_is_a_validation_error(client: httpx.Client) -> None:
    assert_error(client.post("/api/v1/shipments", json={}), 422, "VALIDATION_ERROR")


def test_create_with_an_unknown_carrier_is_rejected(client: httpx.Client, settings: Settings) -> None:
    response = client.post("/api/v1/shipments", json=new_shipment_body(settings, carrier_code="NOPE"))
    assert_error(response, 422, "UNKNOWN_CARRIER")


def test_list_filters_by_carrier_and_status(client: httpx.Client, settings: Settings, shipment: dict) -> None:
    response = client.get("/api/v1/shipments", params={"carrier_code": settings.carrier_code, "status": "CREATED"})
    assert response.status_code == 200
    body = response.json()
    assert set(body) == {"items", "next_cursor"}
    assert body["items"], "the shipment just created must match the filter"
    for item in body["items"]:
        assert set(item) == SHIPMENT_KEYS
        assert item["carrier_code"] == settings.carrier_code
        assert item["status"] == "CREATED"


def test_list_pages_with_an_opaque_cursor(client: httpx.Client, settings: Settings) -> None:
    for _ in range(3):
        create_shipment(client, settings)
    first = client.get("/api/v1/shipments", params={"carrier_code": settings.carrier_code, "limit": 1}).json()
    assert len(first["items"]) == 1
    assert first["next_cursor"], "more shipments exist, so there must be a next cursor"
    second = client.get(
        "/api/v1/shipments",
        params={"carrier_code": settings.carrier_code, "limit": 1, "cursor": first["next_cursor"]},
    ).json()
    assert len(second["items"]) == 1
    assert second["items"][0]["id"] != first["items"][0]["id"]


def test_list_respects_the_limit(client: httpx.Client, settings: Settings) -> None:
    for _ in range(3):
        create_shipment(client, settings)
    body = client.get("/api/v1/shipments", params={"limit": 2}).json()
    assert len(body["items"]) <= 2


@pytest.mark.parametrize("limit", [0, 101, -1])
def test_list_rejects_a_limit_outside_1_to_100(client: httpx.Client, limit: int) -> None:
    assert_error(client.get("/api/v1/shipments", params={"limit": limit}), 422, "VALIDATION_ERROR")


def test_list_rejects_an_unknown_status(client: httpx.Client) -> None:
    assert_error(client.get("/api/v1/shipments", params={"status": "BOGUS"}), 422, "VALIDATION_ERROR")
