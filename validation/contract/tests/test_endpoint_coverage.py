"""Every endpoint in the legacy design's section 3.4 table must be exercised by some test.

This reads the test sources, so it needs no BASE_URL and runs under `pytest --collect-only`.
"""

from pathlib import Path

import pytest

TESTS = Path(__file__).parent

# (method, path template, the call as it appears in the tests)
ENDPOINTS = [
    ("GET", "/", 'client.get("/")'),
    ("POST", "/api/v1/shipments", 'client.post("/api/v1/shipments"'),
    ("GET", "/api/v1/shipments/{id}", 'client.get(f"/api/v1/shipments/{'),
    ("GET", "/api/v1/shipments", 'client.get("/api/v1/shipments"'),
    ("POST", "/api/v1/shipments/{id}/events", "/events"),
    ("GET", "/api/v1/track/{tracking_number}", "/api/v1/track/"),
    ("POST", "/api/v1/shipments/{id}/pod", "/pod"),
    ("GET", "/api/v1/shipments/{id}/pod/{document_id}", "/pod/{"),
    ("GET", "/ui/", 'client.get("/ui/")'),
    ("GET", "/ui/{path}", "/ui/track/"),
    ("GET", "/ui/assets/{file}", "/ui/assets/"),
]


def all_test_source() -> str:
    return "\n".join(p.read_text() for p in sorted(TESTS.glob("test_*.py")) if p.name != Path(__file__).name)


@pytest.mark.parametrize(("method", "path", "marker"), ENDPOINTS, ids=[f"{m} {p}" for m, p, _ in ENDPOINTS])
def test_endpoint_is_exercised(method: str, path: str, marker: str) -> None:
    assert marker in all_test_source(), f"no test calls {method} {path}"
