from __future__ import annotations

from collections.abc import Iterator
from datetime import UTC, datetime, timedelta

import httpx
import pytest

from support import Settings, create_shipment, load_settings, make_client


def pytest_collection_modifyitems(items: list[pytest.Item]) -> None:
    # `full` is everything, so every test carries it; `smoke` is the subset that also says so.
    for item in items:
        item.add_marker(pytest.mark.full)


@pytest.fixture(scope="session")
def settings() -> Settings:
    return load_settings()


@pytest.fixture(scope="session")
def client(settings: Settings) -> Iterator[httpx.Client]:
    with make_client(settings) as session:
        yield session


@pytest.fixture
def shipment(client: httpx.Client, settings: Settings) -> dict:
    """A fresh ZZTEST shipment; every test makes its own, with a unique server-generated number."""
    return create_shipment(client, settings)


@pytest.fixture
def base_time() -> datetime:
    """An hour ago, so event times sit in the past and strictly increase from here."""
    return datetime.now(UTC).replace(microsecond=0) - timedelta(hours=1)
