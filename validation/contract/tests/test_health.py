import httpx
import pytest


@pytest.mark.smoke
def test_root_answers_ok_as_plain_text(client: httpx.Client) -> None:
    response = client.get("/")
    assert response.status_code == 200
    assert response.headers["content-type"].startswith("text/plain")
    assert response.text == "OK"
