"""Proof of delivery: upload, then read back. Both calls must reach one stack, because unpinned
weighted traffic could upload to legacy and read through modern inside the PodSync window (legacy
design section 8). Run with TARGET set to a stack, or SINGLE_STACK=1 when BASE_URL is one stack."""

from __future__ import annotations

import base64
import hashlib
import uuid

import httpx
import pytest

from support import POD_KEYS, Settings, assert_error

pytestmark = pytest.mark.pod

# A one-pixel PNG, a minimal PDF, and the smallest JPEG header: enough for a content-type check.
PNG = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNgYGD4DwABBAEAwS2OUAAAAABJRU5ErkJggg=="
)
PDF = b"%PDF-1.4\n1 0 obj<</Type/Catalog>>endobj\ntrailer<</Root 1 0 R>>\n%%EOF\n"
JPEG = bytes.fromhex("ffd8ffe000104a46494600010100000100010000ffd9")

TEN_MIB = 10 * 1024 * 1024


@pytest.fixture(autouse=True)
def _require_one_stack(settings: Settings) -> None:
    if settings.target == "none" and not settings.single_stack:
        pytest.skip("POD tests need TARGET=legacy|modern (or SINGLE_STACK=1 when BASE_URL is one stack)")


def upload(client: httpx.Client, shipment_id: str, content: bytes, content_type: str) -> httpx.Response:
    return client.post(
        f"/api/v1/shipments/{shipment_id}/pod", files={"file": ("proof", content, content_type)}
    )


@pytest.mark.parametrize(
    ("content", "content_type"),
    [
        pytest.param(PNG, "image/png", id="png"),
        pytest.param(PDF, "application/pdf", id="pdf"),
        pytest.param(JPEG, "image/jpeg", id="jpeg"),
    ],
)
def test_upload_then_read_back(client: httpx.Client, shipment: dict, content: bytes, content_type: str) -> None:
    response = upload(client, shipment["id"], content, content_type)
    assert response.status_code == 201, response.text[:200]
    body = response.json()
    assert set(body) == POD_KEYS
    assert body["shipment_id"] == shipment["id"]
    assert body["content_type"] == content_type
    assert body["size_bytes"] == len(content)
    assert body["sha256"] == hashlib.sha256(content).hexdigest()

    # httpx follows redirects: modern answers with a 302 to a presigned URL.
    download = client.get(f"/api/v1/shipments/{shipment['id']}/pod/{body['document_id']}")
    assert download.status_code == 200
    assert download.headers["content-type"].split(";")[0] == content_type
    assert download.content == content


def test_upload_rejects_an_unsupported_type(client: httpx.Client, shipment: dict) -> None:
    assert_error(upload(client, shipment["id"], b"plain text", "text/plain"), 415, "UNSUPPORTED_MEDIA_TYPE")


def test_upload_rejects_a_file_over_10_mib(client: httpx.Client, shipment: dict) -> None:
    response = upload(client, shipment["id"], b"\0" * (TEN_MIB + 1), "image/png")
    assert_error(response, 413, "PAYLOAD_TOO_LARGE")


def test_upload_accepts_exactly_10_mib(client: httpx.Client, shipment: dict) -> None:
    response = upload(client, shipment["id"], PNG + b"\0" * (TEN_MIB - len(PNG)), "image/png")
    assert response.status_code == 201, response.text[:200]


def test_upload_to_an_unknown_shipment_is_404(client: httpx.Client) -> None:
    assert_error(upload(client, str(uuid.uuid4()), PNG, "image/png"), 404, "NOT_FOUND")


def test_reading_an_unknown_document_is_404(client: httpx.Client, shipment: dict) -> None:
    assert_error(client.get(f"/api/v1/shipments/{shipment['id']}/pod/{uuid.uuid4()}"), 404, "NOT_FOUND")
