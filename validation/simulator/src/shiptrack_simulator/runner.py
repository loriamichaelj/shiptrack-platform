"""Send a plan to a stack, recording every accepted event in the ledger."""

from __future__ import annotations

import asyncio
import random
import time
import uuid
from dataclasses import dataclass, field
from typing import Any

import httpx

from .ledger import Ledger, LedgerEntry, now_iso
from .plan import PlannedEvent, ShipmentPlan
from .proof_of_delivery import make_proof_of_delivery


@dataclass
class Stats:
    shipments_created: int = 0
    shipments_failed: int = 0
    events_accepted: int = 0
    events_rejected: int = 0
    duplicates_sent: int = 0
    out_of_order_sent: int = 0
    exception_paths: int = 0
    late_shipments: int = 0
    proofs_uploaded: int = 0
    proofs_failed: int = 0
    errors: list[str] = field(default_factory=list)

    def summary(self) -> str:
        lines = [
            f"shipments created      {self.shipments_created} ({self.shipments_failed} failed)",
            f"events accepted (202)  {self.events_accepted} ({self.events_rejected} not accepted)",
            f"duplicate sends        {self.duplicates_sent}",
            f"out-of-order sends     {self.out_of_order_sent}",
            f"exception paths        {self.exception_paths}",
            f"created already late   {self.late_shipments}",
            f"proofs uploaded        {self.proofs_uploaded} ({self.proofs_failed} failed)",
        ]
        return "\n".join(lines)


RETRY_STATUSES = frozenset({502, 503, 504})


async def _post(
    client: httpx.AsyncClient, url: str, *, retry_seconds: float, **kwargs: Any
) -> httpx.Response:
    """POST, and try again after a connection error or a 502, 503, or 504 for up to `retry_seconds`.

    A client behind a load balancer or a port-forward sees these while pods are replaced. An event is sent
    again with the same Idempotency-Key, which is what the key is for; a shipment create has no key, so a
    retry after a dropped connection can leave one extra shipment, which does no harm. With 0 nothing is tried
    again.
    """
    deadline = time.monotonic() + retry_seconds
    wait = 0.5
    while True:
        try:
            response = await client.post(url, **kwargs)
        except httpx.TransportError:
            if time.monotonic() >= deadline:
                raise
        else:
            if response.status_code not in RETRY_STATUSES or time.monotonic() >= deadline:
                return response
        await asyncio.sleep(wait)
        wait = min(wait * 2, 5.0)


def headers_for(target: str, token: str) -> dict[str, str]:
    if target == "none":
        return {}
    return {"X-ShipTrack-Target": target, "X-ShipTrack-Test-Token": token}


async def _send_event(
    client: httpx.AsyncClient,
    ledger: Ledger,
    stats: Stats,
    *,
    run_id: str,
    shipment: dict[str, str],
    event: PlannedEvent,
    retry_seconds: float,
) -> None:
    key = f"sim-{run_id}-{event.key_suffix}"
    if event.duplicate:
        stats.duplicates_sent += 1
    if event.out_of_order:
        stats.out_of_order_sent += 1
    try:
        response = await _post(
            client,
            f"/api/v1/shipments/{shipment['id']}/events",
            retry_seconds=retry_seconds,
            json={
                "event_type": event.event_type,
                "location": event.location,
                "occurred_at": event.occurred_at.strftime("%Y-%m-%dT%H:%M:%SZ"),
            },
            headers={"Idempotency-Key": key},
        )
    except httpx.HTTPError as error:
        stats.events_rejected += 1
        stats.errors.append(f"event send failed: {type(error).__name__}")
        return
    if response.status_code == 202:
        stats.events_accepted += 1
        ledger.record(
            LedgerEntry(
                idempotency_key=key,
                shipment_id=shipment["id"],
                tracking_number=shipment["tracking_number"],
                event_type=event.event_type,
                occurred_at=event.occurred_at.strftime("%Y-%m-%dT%H:%M:%SZ"),
                accepted_at=now_iso(),
            )
        )
    else:
        stats.events_rejected += 1
        stats.errors.append(f"event not accepted: HTTP {response.status_code}")


async def _run_shipment(
    client: httpx.AsyncClient,
    ledger: Ledger,
    stats: Stats,
    rng: random.Random,
    *,
    run_id: str,
    plan: ShipmentPlan,
    delay: float,
    retry_seconds: float,
) -> None:
    try:
        created = await _post(
            client,
            "/api/v1/shipments",
            retry_seconds=retry_seconds,
            json={
                "carrier_code": plan.carrier_code,
                "origin": plan.origin,
                "destination": plan.destination,
                "promised_delivery_at": plan.promised_delivery_at.strftime("%Y-%m-%dT%H:%M:%SZ"),
            },
        )
    except httpx.HTTPError as error:
        stats.shipments_failed += 1
        stats.errors.append(f"create failed: {type(error).__name__}")
        return
    if created.status_code != 201:
        stats.shipments_failed += 1
        stats.errors.append(f"create not accepted: HTTP {created.status_code}")
        return
    body = created.json()
    shipment = {"id": body["id"], "tracking_number": body["tracking_number"]}
    stats.shipments_created += 1
    stats.late_shipments += int(plan.late)
    stats.exception_paths += int(plan.exception_path)

    for event in plan.events:
        await _send_event(
            client, ledger, stats, run_id=run_id, shipment=shipment, event=event, retry_seconds=retry_seconds
        )
        if delay:
            await asyncio.sleep(delay)

    if plan.delivers:
        content, content_type = make_proof_of_delivery(rng, f"{run_id}-{shipment['tracking_number']}")
        try:
            proof = await _post(
                client,
                f"/api/v1/shipments/{shipment['id']}/pod",
                retry_seconds=retry_seconds,
                files={"file": ("proof", content, content_type)},
            )
        except httpx.HTTPError as error:
            stats.proofs_failed += 1
            stats.errors.append(f"proof-of-delivery upload failed: {type(error).__name__}")
            return
        if proof.status_code == 201:
            stats.proofs_uploaded += 1
        else:
            stats.proofs_failed += 1
            stats.errors.append(f"proof of delivery not accepted: HTTP {proof.status_code}")


async def run(
    plans: list[ShipmentPlan],
    *,
    base_url: str,
    target: str,
    token: str,
    ledger: Ledger,
    concurrency: int = 10,
    delay: float = 0.0,
    seed: int = 0,
    retry_seconds: float = 0.0,
    transport: httpx.AsyncBaseTransport | None = None,
) -> Stats:
    stats = Stats()
    run_id = uuid.uuid4().hex[:8]
    rng = random.Random(seed)
    gate = asyncio.Semaphore(concurrency)

    async with httpx.AsyncClient(
        base_url=base_url,
        headers=headers_for(target, token),
        timeout=httpx.Timeout(30.0),
        follow_redirects=True,
        transport=transport,
    ) as client:

        async def one(plan: ShipmentPlan) -> None:
            async with gate:
                await _run_shipment(
                    client,
                    ledger,
                    stats,
                    rng,
                    run_id=run_id,
                    plan=plan,
                    delay=delay,
                    retry_seconds=retry_seconds,
                )

        await asyncio.gather(*(one(plan) for plan in plans))
    return stats
