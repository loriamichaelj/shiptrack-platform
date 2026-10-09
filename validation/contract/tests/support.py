"""Settings, helpers, and the HTTP client the contract tests share.

The suite is the executable form of shiptrack-legacy docs/DESIGN.md section 3. If a test and that
prose disagree, raise it as an issue rather than changing either quietly.
"""

from __future__ import annotations

import os
import re
import time
import uuid
from collections.abc import Callable
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from typing import Any
from urllib.parse import urlsplit

import httpx

TARGETS = ("legacy", "modern", "none")
STACK_HEADER = "X-ShipTrack-Stack"
TRACKING_NUMBER = re.compile(r"^MF[0-9]{10}$")
ISO_UTC = re.compile(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?Z$")

SHIPMENT_KEYS = {
    "id",
    "tracking_number",
    "carrier_code",
    "origin",
    "destination",
    "status",
    "promised_delivery_at",
    "estimated_delivery_at",
    "delivered_at",
    "sla_breached",
    "created_at",
    "updated_at",
}
TRACK_VIEW_KEYS = {"tracking_number", "carrier_code", "status", "estimated_delivery_at", "delivered_at", "events"}
TRACK_EVENT_KEYS = {"event_type", "location", "occurred_at"}
POD_KEYS = {"document_id", "shipment_id", "content_type", "size_bytes", "sha256", "uploaded_at"}


@dataclass(frozen=True)
class Settings:
    base_url: str
    target: str
    token: str
    carrier_code: str
    single_stack: bool

    @property
    def host(self) -> str:
        return urlsplit(self.base_url).netloc


def load_settings() -> Settings:
    base_url = os.environ.get("BASE_URL", "").rstrip("/")
    if not base_url:
        raise RuntimeError("BASE_URL is required, for example BASE_URL=http://localhost:8000")
    target = os.environ.get("TARGET", "none")
    if target not in TARGETS:
        raise RuntimeError(f"TARGET must be one of {', '.join(TARGETS)}, not {target!r}")
    return Settings(
        base_url=base_url,
        target=target,
        token=os.environ.get("TEST_TOKEN", ""),
        carrier_code=os.environ.get("CARRIER_CODE", "ZZTEST"),
        # Set when BASE_URL points straight at one stack and not at the ALB, so nothing can route a
        # request to the other stack. It lets the POD tests run without a pinned target.
        single_stack=os.environ.get("SINGLE_STACK", "") == "1",
    )


class RoutingFallThrough(AssertionError):
    """A response came from a different stack than TARGET asked for."""


def _error_code(response: httpx.Response) -> str | None:
    if response.status_code < 400:
        return None
    try:
        body = response.json()
    except ValueError:
        return None
    error = body.get("error") if isinstance(body, dict) else None
    return error.get("code") if isinstance(error, dict) else None


def make_client(settings: Settings, *, target: str | None = None) -> httpx.Client:
    """An httpx client for one target, with routing and error-code checks on every response."""
    target = settings.target if target is None else target
    headers: dict[str, str] = {}
    if target != "none":
        headers["X-ShipTrack-Target"] = target
        headers["X-ShipTrack-Test-Token"] = settings.token

    def strip_routing_headers_off_site(request: httpx.Request) -> None:
        # modern answers a POD download with a redirect to a presigned URL; the token must not follow.
        if request.url.host != settings.host.split(":")[0]:
            for name in [h for h in request.headers if h.lower().startswith("x-shiptrack-")]:
                del request.headers[name]

    def check_response(response: httpx.Response) -> None:
        if response.request.url.host != settings.host.split(":")[0]:
            return
        response.read()
        stack = response.headers.get(STACK_HEADER)
        if target != "none" and stack != target:
            raise RoutingFallThrough(
                f"expected {STACK_HEADER}: {target} but got {stack!r}. Routing fell through to the "
                "weighted rules: check the test token and the X-ShipTrack-Target header."
            )
        code = _error_code(response)
        if code == "INJECTED_FAULT":
            raise AssertionError("INJECTED_FAULT is for game days only and is always a failure")
        if code == "QUEUE_UNAVAILABLE" and stack != "modern":
            raise AssertionError("QUEUE_UNAVAILABLE is only valid from the modern stack")

    return httpx.Client(
        base_url=settings.base_url,
        headers=headers,
        follow_redirects=True,
        timeout=httpx.Timeout(20.0),
        event_hooks={"request": [strip_routing_headers_off_site], "response": [check_response]},
    )


def iso(moment: datetime) -> str:
    return moment.astimezone(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_iso(value: str) -> datetime:
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def assert_error(response: httpx.Response, status: int, code: str) -> None:
    assert response.status_code == status, f"expected {status}, got {response.status_code}: {response.text[:200]}"
    body = response.json()
    assert set(body) == {"error"}, f"error envelope must have only an 'error' key, got {sorted(body)}"
    assert set(body["error"]) == {"code", "message", "request_id"}, sorted(body["error"])
    assert body["error"]["code"] == code
    assert isinstance(body["error"]["message"], str) and body["error"]["message"]


def new_shipment_body(settings: Settings, **overrides: Any) -> dict[str, Any]:
    body = {
        "carrier_code": settings.carrier_code,
        "origin": "Leeds",
        "destination": "Cardiff",
        "promised_delivery_at": iso(datetime.now(UTC) + timedelta(days=30)),
    }
    body.update(overrides)
    return body


def create_shipment(client: httpx.Client, settings: Settings, **overrides: Any) -> dict[str, Any]:
    response = client.post("/api/v1/shipments", json=new_shipment_body(settings, **overrides))
    assert response.status_code == 201, f"create failed: {response.status_code} {response.text[:200]}"
    return response.json()


def post_event(
    client: httpx.Client,
    shipment_id: str,
    event_type: str,
    occurred_at: datetime,
    *,
    key: str | None = None,
    location: str = "Depot",
    payload: dict[str, Any] | None = None,
) -> httpx.Response:
    body: dict[str, Any] = {"event_type": event_type, "location": location, "occurred_at": iso(occurred_at)}
    if payload is not None:
        body["payload"] = payload
    return client.post(
        f"/api/v1/shipments/{shipment_id}/events",
        json=body,
        headers={"Idempotency-Key": key or f"contract-{uuid.uuid4().hex}"},
    )


def wait_for(
    check: Callable[[], Any], *, timeout: float = 15.0, interval: float = 0.25, what: str = "the condition"
) -> Any:
    """Poll `check` until it returns something truthy. Event ingestion is asynchronous (202)."""
    deadline = time.monotonic() + timeout
    last: Any = None
    while time.monotonic() < deadline:
        last = check()
        if last:
            return last
        time.sleep(interval)
    raise AssertionError(f"timed out after {timeout:.0f}s waiting for {what}")


def track(client: httpx.Client, tracking_number: str) -> dict[str, Any]:
    response = client.get(f"/api/v1/track/{tracking_number}")
    assert response.status_code == 200, f"track failed: {response.status_code} {response.text[:200]}"
    return response.json()


def wait_for_status(client: httpx.Client, tracking_number: str, status: str) -> dict[str, Any]:
    return wait_for(
        lambda: (view := track(client, tracking_number))["status"] == status and view,
        what=f"{tracking_number} to reach {status}",
    )


def settle(seconds: float = 2.0) -> None:
    """Wait long enough for an event that should be ignored to have been processed."""
    time.sleep(seconds)
