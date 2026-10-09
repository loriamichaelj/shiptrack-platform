from datetime import UTC, datetime

from shiptrack_simulator.plan import EXCEPTION_PATH, HAPPY_PATH, plan_run

NOW = datetime(2026, 10, 9, 12, 0, 0, tzinfo=UTC)


def test_the_same_seed_plans_the_same_run() -> None:
    assert plan_run(7, 50, NOW) == plan_run(7, 50, NOW)


def test_a_different_seed_plans_a_different_run() -> None:
    assert plan_run(7, 50, NOW) != plan_run(8, 50, NOW)


def test_every_shipment_tells_a_complete_story() -> None:
    for plan in plan_run(1, 200, NOW):
        sent = [e.event_type for e in plan.events if not e.duplicate]
        expected = EXCEPTION_PATH if plan.exception_path else HAPPY_PATH
        assert sorted(sent) == sorted(expected)
        assert plan.delivers


def test_event_times_are_not_in_the_future() -> None:
    for plan in plan_run(2, 200, NOW):
        assert all(e.occurred_at <= NOW for e in plan.events)


def test_rates_are_close_to_the_design() -> None:
    plans = plan_run(3, 4000, NOW)
    events = [e for p in plans for e in p.events]
    originals = [e for e in events if not e.duplicate]
    duplicates = sum(e.duplicate for e in events) / len(originals)
    out_of_order = sum(e.out_of_order for e in events) / len(originals)
    exceptions = sum(p.exception_path for p in plans) / len(plans)
    late = sum(p.late for p in plans) / len(plans)
    assert 0.005 < duplicates < 0.02
    assert 0.01 < out_of_order < 0.035
    assert 0.003 < exceptions < 0.02
    assert 0.035 < late < 0.065


def test_late_shipments_were_promised_in_the_past() -> None:
    plans = plan_run(4, 500, NOW)
    assert any(p.late for p in plans)
    for plan in plans:
        assert (plan.promised_delivery_at < NOW) == plan.late


def test_a_duplicate_repeats_the_key_of_an_earlier_event() -> None:
    for plan in plan_run(5, 2000, NOW):
        seen: set[str] = set()
        for event in plan.events:
            if event.duplicate:
                assert event.key_suffix in seen
            seen.add(event.key_suffix)
