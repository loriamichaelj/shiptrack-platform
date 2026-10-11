"""An overdue shipment is flagged by the SLA scan, once.

The scan runs every five minutes, so this waits for it: it is a marker of its own (`sla`) and is
left out of `contract-full`. It cannot count alerts, which are in the private database; it shows that
the scan flags every overdue shipment it is given and that the flag does not change afterwards. The
alert count is read with `check-evidence.yml sla-duplicates` before and after: it grows by the number of
shipments created here and `extra_alerts` stays 0.
"""

from __future__ import annotations

import time
from datetime import UTC, datetime, timedelta

import httpx
import pytest

from support import Settings, create_shipment, iso

SHIPMENTS = 3
POLL_SECONDS = 15
DEADLINE_SECONDS = 12 * 60


@pytest.mark.sla
def test_the_sla_scan_flags_overdue_shipments_once(client: httpx.Client, settings: Settings) -> None:
    promised = iso(datetime.now(UTC) - timedelta(hours=2))
    ids = [
        create_shipment(client, settings, promised_delivery_at=promised)["id"]
        for _ in range(SHIPMENTS)
    ]

    deadline = time.monotonic() + DEADLINE_SECONDS
    flagged: dict[str, str] = {}
    while time.monotonic() < deadline and len(flagged) < len(ids):
        for shipment_id in ids:
            if shipment_id in flagged:
                continue
            body = client.get(f"/api/v1/shipments/{shipment_id}").json()
            if body["sla_breached"] is True:
                flagged[shipment_id] = body["updated_at"]
        if len(flagged) < len(ids):
            time.sleep(POLL_SECONDS)

    missed = len(ids) - len(flagged)
    assert not missed, f"{missed} of {len(ids)} overdue shipments were not flagged in {DEADLINE_SECONDS}s"

    # A second scan must not touch a flagged shipment again.
    time.sleep(POLL_SECONDS)
    for shipment_id, updated_at in flagged.items():
        again = client.get(f"/api/v1/shipments/{shipment_id}").json()
        assert again["sla_breached"] is True
        assert again["updated_at"] == updated_at, "a flagged shipment was updated again"
