"""What the simulator will send, decided up front from a seed so a run can be repeated.

Rates follow the validation design: 1% duplicate events, 2% out-of-order events, 1% of shipments
take an EXCEPTION path, and 5% of shipments are created already late, to trigger the SLA scanner.
"""

from __future__ import annotations

import random
from dataclasses import dataclass, field
from datetime import UTC, datetime, timedelta

CARRIERS = ("ACME", "BOLT", "CRWN", "MFLT")
CITIES = ("Leeds", "Cardiff", "Bristol", "Glasgow", "Norwich", "Exeter", "Derby", "Hull", "York", "Bath")

DUPLICATE_RATE = 0.01
OUT_OF_ORDER_RATE = 0.02
EXCEPTION_RATE = 0.01
LATE_RATE = 0.05

HAPPY_PATH = ("PICKED_UP", "IN_TRANSIT", "OUT_FOR_DELIVERY", "DELIVERED")
EXCEPTION_PATH = ("PICKED_UP", "IN_TRANSIT", "EXCEPTION", "IN_TRANSIT", "OUT_FOR_DELIVERY", "DELIVERED")


@dataclass(frozen=True)
class PlannedEvent:
    """One request to send. `duplicate_of` marks a repeat of an earlier key."""

    event_type: str
    location: str
    occurred_at: datetime
    key_suffix: str
    duplicate: bool = False
    out_of_order: bool = False


@dataclass(frozen=True)
class ShipmentPlan:
    carrier_code: str
    origin: str
    destination: str
    promised_delivery_at: datetime
    late: bool
    exception_path: bool
    events: list[PlannedEvent] = field(default_factory=list)

    @property
    def delivers(self) -> bool:
        return any(e.event_type == "DELIVERED" and not e.duplicate for e in self.events)


def plan_shipment(rng: random.Random, now: datetime, index: int) -> ShipmentPlan:
    """Plan one shipment and the sequence of event requests that tells its story."""
    carrier = rng.choice(CARRIERS)
    origin, destination = rng.sample(CITIES, 2)
    late = rng.random() < LATE_RATE
    # Late shipments were promised in the past, so the SLA scan has something to find.
    promised = now - timedelta(hours=rng.randint(1, 48)) if late else now + timedelta(days=rng.randint(2, 10))
    exception_path = rng.random() < EXCEPTION_RATE
    path = EXCEPTION_PATH if exception_path else HAPPY_PATH

    # Event times run forward from some point in the past, with jitter between steps.
    span_minutes = sum(rng.randint(3, 25) for _ in path)
    moment = now - timedelta(minutes=span_minutes)
    timeline: list[PlannedEvent] = []
    for step, event_type in enumerate(path):
        moment += timedelta(minutes=rng.randint(3, 25), seconds=rng.randint(0, 59))
        timeline.append(
            PlannedEvent(
                event_type=event_type,
                location=rng.choice(CITIES),
                occurred_at=min(moment, now).replace(microsecond=0),
                key_suffix=f"{index}-{step}",
            )
        )

    # Out of order: an event reaches us after the one that follows it.
    for position in range(len(timeline) - 1):
        if rng.random() < OUT_OF_ORDER_RATE:
            timeline[position], timeline[position + 1] = timeline[position + 1], timeline[position]
            # The earlier event is the one that arrives late.
            timeline[position + 1] = _flag(timeline[position + 1], out_of_order=True)

    # Duplicates: the same event, with the same key, sent again straight after.
    with_duplicates: list[PlannedEvent] = []
    for event in timeline:
        with_duplicates.append(event)
        if rng.random() < DUPLICATE_RATE:
            with_duplicates.append(_flag(event, duplicate=True))

    return ShipmentPlan(
        carrier_code=carrier,
        origin=origin,
        destination=destination,
        promised_delivery_at=promised.replace(microsecond=0),
        late=late,
        exception_path=exception_path,
        events=with_duplicates,
    )


def _flag(
    event: PlannedEvent, *, duplicate: bool | None = None, out_of_order: bool | None = None
) -> PlannedEvent:
    return PlannedEvent(
        event_type=event.event_type,
        location=event.location,
        occurred_at=event.occurred_at,
        key_suffix=event.key_suffix,
        duplicate=event.duplicate if duplicate is None else duplicate,
        out_of_order=event.out_of_order if out_of_order is None else out_of_order,
    )


def plan_run(seed: int, shipments: int, now: datetime | None = None) -> list[ShipmentPlan]:
    rng = random.Random(seed)
    moment = (now or datetime.now(UTC)).replace(microsecond=0)
    return [plan_shipment(rng, moment, index) for index in range(shipments)]
