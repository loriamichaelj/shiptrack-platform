"""Small generated proof-of-delivery files. The simulator uploads them and never reads them back
through weighted routing: an upload and a read must reach the same stack."""

from __future__ import annotations

import base64
import random

_PNG = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNgYGD4DwABBAEAwS2OUAAAAABJRU5ErkJggg=="
)


def make_pod(rng: random.Random, serial: str) -> tuple[bytes, str]:
    """A tiny PNG or PDF with a serial in it so that no two files are identical."""
    if rng.random() < 0.5:
        return _PNG + b"\0" + serial.encode(), "image/png"
    body = (
        f"%PDF-1.4\n% proof of delivery {serial}\n"
        "1 0 obj<</Type/Catalog>>endobj\ntrailer<</Root 1 0 R>>\n%%EOF\n"
    )
    return body.encode(), "application/pdf"
