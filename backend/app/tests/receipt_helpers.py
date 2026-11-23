"""Test helpers: request bodies for confirming receipt
(POST /deliveries/{id}/confirm-receipt and POST /trips/{id}/confirm-receipt).

J1 / NF-009: every line counted (counts_as_sent).
J2 / NF-015: plus the proof of receipt:
  - the handover code, which the helper gets the way the staff on site
    would: POST /deliveries/{id}/handover-code as CSWS Main Office (it logs
    in as the CSWS test account itself, so callers pass only the rep's
    headers);
  - the signer's name and position (SIGNER);
  - a small signature PNG uploaded by the confirming user.
"""
import io
import os

from PIL import Image

SIGNER = {"signer_name": "Ana Test", "signer_position": "Barangay Secretary"}

# Well-formed bodies for tests that expect the request to be refused before
# the code and counts are looked at (wrong role, wrong barangay, not
# arrived yet).
ANY_PROOF = {"handover_code": "000000", **SIGNER,
             "signature_file_id": "00000000-0000-0000-0000-000000000000"}
ANY_COUNTS = {"items": [{"delivery_item_id": 0, "received_quantity": 0}], **ANY_PROOF}
ANY_TRIP_COUNTS = {"deliveries": [{"delivery_id": 0, "items": ANY_COUNTS["items"]}], **ANY_PROOF}


def image_bytes(fmt: str = "PNG", size=(120, 40), noise: bool = False, quality: int = 90) -> bytes:
    """A small test image: a white strip with one dark line (a 'signature'),
    or random noise (large, hard to compress)."""
    if noise:
        img = Image.frombytes("RGB", size, os.urandom(size[0] * size[1] * 3))
    else:
        img = Image.new("RGB", size, "white")
        for x in range(10, size[0] - 10):
            img.putpixel((x, size[1] // 2), (0, 0, 0))
    out = io.BytesIO()
    if fmt == "JPEG":
        img.save(out, "JPEG", quality=quality)
    else:
        img.save(out, fmt)
    return out.getvalue()


def upload(client, headers, purpose: str, data: bytes, filename: str):
    """POST /uploads as [headers]; the type is read from the bytes."""
    return client.post("/uploads", headers=headers, data={"purpose": purpose},
                       files={"file": (filename, data, "application/octet-stream")})


def upload_signature(client, headers) -> str:
    """A signature PNG uploaded by the confirming user; returns its file_id."""
    r = upload(client, headers, "receipt_signature", image_bytes("PNG"), "signature.png")
    assert r.status_code == 201, r.text
    return r.json()["file_id"]


def csws_headers(client) -> dict:
    """The CSWS Main Office test account's headers (logged in once per client)."""
    cached = getattr(client, "_csws_headers_for_receipts", None)
    if cached is not None:
        return cached
    # Imported here: tests/test_role_flows.py imports this module.
    from tests.m1_user_management.test_role_flows import ACCOUNTS, PASSWORD
    r = client.post("/token", data={"username": ACCOUNTS["csws"][0], "password": PASSWORD})
    assert r.status_code == 200, r.text
    headers = {"Authorization": f"Bearer {r.json()['access_token']}"}
    client._csws_headers_for_receipts = headers
    return headers


def handover_code(client, delivery_id) -> str:
    """A fresh handover code, as CSWS Main Office on site would show it.
    Replaces any older code (for a trip stop, the code of every delivery
    waiting there)."""
    r = client.post(f"/deliveries/{delivery_id}/handover-code", headers=csws_headers(client))
    assert r.status_code == 200, r.text
    return r.json()["handover_code"]


def proof(client, delivery_id, headers) -> dict:
    """The J2 proof fields for confirming [delivery_id] as [headers]."""
    return {"handover_code": handover_code(client, delivery_id), **SIGNER,
            "signature_file_id": upload_signature(client, headers)}


def counts_as_sent(items) -> list:
    """Every line counted exactly as CSWS sent it."""
    return [{"delivery_item_id": i["delivery_item_id"], "received_quantity": i["quantity"]}
            for i in items]


def full_counts(client, delivery_id, headers, remarks=None) -> dict:
    """Body for POST /deliveries/{id}/confirm-receipt: every line counted as
    sent, plus the code, the signer and a signature. headers: the
    confirming user (the rep of that barangay)."""
    r = client.get(f"/deliveries/{delivery_id}", headers=headers)
    assert r.status_code == 200, r.text
    body = {"items": counts_as_sent(r.json()["items"]), **proof(client, delivery_id, headers)}
    if remarks is not None:
        body["remarks"] = remarks
    return body


def trip_counts(client, trip_id, headers, remarks=None) -> dict:
    """Body for POST /trips/{id}/confirm-receipt: every delivery of the trip
    that arrived at the rep's barangay, each line counted as sent, plus the
    stop's one code and one signature. headers: the rep's own."""
    r = client.get("/deliveries/", headers=headers,
                   params={"trip_id": trip_id, "status": "Delivered"})
    assert r.status_code == 200, r.text
    rows = r.json()
    body = {"deliveries": [{"delivery_id": d["delivery_id"], "items": counts_as_sent(d["items"])}
                           for d in rows]}
    if rows:
        body.update(proof(client, rows[0]["delivery_id"], headers))
    if remarks is not None:
        body["remarks"] = remarks
    return body
