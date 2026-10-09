"""The served UI shell and its assets (marker ui, part of smoke). Needs a stack that serves /ui/: in
legacy that is nginx, so these tests do not apply to the bare application process."""

from __future__ import annotations

import re

import httpx
import pytest

pytestmark = [pytest.mark.ui, pytest.mark.smoke]

ASSET = re.compile(r"""(?:src|href)=["'](/ui/assets/[^"']+)["']""")
IMMUTABLE = "public, max-age=31536000, immutable"


def shell(client: httpx.Client) -> httpx.Response:
    response = client.get("/ui/")
    assert response.status_code == 200
    return response


def test_ui_shell(client: httpx.Client) -> None:
    response = shell(client)
    assert response.headers["content-type"].split(";")[0] == "text/html"
    assert '<div id="root">' in response.text
    assert response.headers["cache-control"] == "no-cache"


def test_every_referenced_asset_is_served_immutable_from_the_same_target(client: httpx.Client) -> None:
    assets = ASSET.findall(shell(client).text)
    assert assets, "the shell must reference at least one /ui/assets/ file"
    for path in assets:
        response = client.get(path)
        assert response.status_code == 200, f"{path} returned {response.status_code}"
        assert response.headers["cache-control"] == IMMUTABLE, path


def test_a_deep_link_returns_the_shell_not_404(client: httpx.Client) -> None:
    deep = client.get("/ui/track/MF0000000000")
    assert deep.status_code == 200
    assert deep.text == shell(client).text


def test_a_missing_asset_is_404(client: httpx.Client) -> None:
    assert client.get("/ui/assets/does-not-exist.js").status_code == 404
