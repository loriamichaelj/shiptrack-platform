"""Cutover gate G6: both stacks must serve the same UI build. Run only when both are deployed."""

from __future__ import annotations

import re

import pytest

from support import Settings, make_client

pytestmark = pytest.mark.ui_parity

ASSET = re.compile(r"""(?:src|href)=["'](/ui/assets/[^"']+)["']""")


def asset_names(settings: Settings, target: str) -> list[str]:
    with make_client(settings, target=target) as client:
        response = client.get("/ui/")
        assert response.status_code == 200, f"/ui/ on {target} returned {response.status_code}"
        return sorted(ASSET.findall(response.text))


def test_both_stacks_reference_identical_asset_files(settings: Settings) -> None:
    if not settings.token:
        pytest.skip("TEST_TOKEN is needed to address each stack directly")
    legacy = asset_names(settings, "legacy")
    modern = asset_names(settings, "modern")
    assert legacy, "legacy references no assets"
    assert legacy == modern, (
        "the UI builds differ between the stacks: build both with the exact Node version in web/.nvmrc"
    )
