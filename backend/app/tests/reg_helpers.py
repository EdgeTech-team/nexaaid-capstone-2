"""Shared steps for tests that register accounts the way the app does:
upload the files first (POST /uploads, no login), then send the register
request with {file_id, claim_token} for each file (UC-D1, UC-A2)."""
import io

from PIL import Image

# Meets core/passwords.validate_password_strength (a letter and a number).
STRONG_PASSWORD = "Relief#2026ok"


def png(color="white") -> bytes:
    buf = io.BytesIO()
    Image.new("RGB", (40, 30), color).save(buf, "PNG")
    return buf.getvalue()


def pdf() -> bytes:
    return b"%PDF-1.4\n1 0 obj<<>>endobj\ntrailer<<>>\n%%EOF\n"


def upload(client, purpose, data=None, headers=None, name="photo.png") -> dict:
    r = client.post(
        "/uploads",
        data={"purpose": purpose},
        files={"file": (name, data if data is not None else png(), "application/octet-stream")},
        headers=headers or {},
    )
    assert r.status_code == 201, r.text
    j = r.json()
    return j


def ref(up: dict) -> dict:
    return {"file_id": up["file_id"], "claim_token": up["claim_token"]}


def donor_payload(client, email, **overrides) -> dict:
    # D1: id_type is no longer sent (it is optional). D3: accepted_terms is required.
    body = {
        "first_name": "new", "last_name": "donor", "email": email,
        "contact_number": "09171234567",
        "password": STRONG_PASSWORD, "confirm_password": STRONG_PASSWORD,
        "id_front": ref(upload(client, "id_front")),
        "id_back": ref(upload(client, "id_back", png("gray"))),
        "consent": True,
        "accepted_terms": True,
    }
    body.update(overrides)
    return body


def org_payload(client, email, registration_no="REG-2026-01", **overrides) -> dict:
    # D3: accepted_terms is required for organizations too.
    body = {
        "org_name": "Relief PH", "organization_type": "NGO",
        "address": "Tipolo, Mandaue City", "contact_first_name": "jo",
        "contact_last_name": "santos", "registration_no": registration_no,
        "contact_email": email, "contact_number": "09171234567",
        "password": STRONG_PASSWORD, "confirm_password": STRONG_PASSWORD,
        "legitimacy_document": ref(upload(client, "legitimacy_document", pdf(), name="sec.pdf")),
        "consent": True,
        "accepted_terms": True,
    }
    body.update(overrides)
    return body