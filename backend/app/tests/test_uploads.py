"""
backend/app/tests/test_uploads.py — Sprint 0 upload service.

Uses the real-auth `api` fixture from test_role_flows (real /token login,
real roles), with files written to a temp folder instead of var/uploads.
"""
import io

import pytest
from fastapi import HTTPException
from PIL import Image

import core.database as database
from core.storage import LocalStorage, set_storage
from core.uploads import MAX_BYTES, claim_upload
from models.user_rbac_model import User
from tests.test_role_flows import api, ok  # noqa: F401  (fixture)

MAKE = 0x010F  # EXIF "camera maker" tag, stands in for GPS data


@pytest.fixture()
def files(api, tmp_path):
    previous = set_storage(LocalStorage(tmp_path))
    yield api
    set_storage(previous)


def png() -> bytes:
    buf = io.BytesIO()
    Image.new("RGB", (40, 30), "white").save(buf, "PNG")
    return buf.getvalue()


def jpeg_with_exif() -> bytes:
    exif = Image.Exif()
    exif[MAKE] = "PhoneMaker"
    buf = io.BytesIO()
    Image.new("RGB", (40, 30), "red").save(buf, "JPEG", exif=exif.tobytes())
    return buf.getvalue()


def post(client, purpose, data, headers=None, name="photo.png"):
    return client.post(
        "/uploads",
        data={"purpose": purpose},
        files={"file": (name, data, "application/octet-stream")},
        headers=headers or {},
    )


def test_anonymous_private_upload_is_hidden_from_everyone_but_admin(files):
    client, t = files
    up = ok(post(client, "id_front", png()), 201)
    assert up["url"] == f"/uploads/{up['file_id']}"
    assert up["visibility"] == "private" and up["claim_token"]

    assert client.get(up["url"]).status_code == 404                     # anonymous
    assert client.get(up["url"], headers=t["donor"]).status_code == 404  # not the owner
    r = client.get(up["url"], headers=t["admin"])                        # UC-A2 review
    assert r.status_code == 200 and r.headers["cache-control"] == "private, no-store"


def test_logged_in_upload_is_owned_and_exif_is_stripped(files):
    client, t = files
    raw = jpeg_with_exif()
    assert Image.open(io.BytesIO(raw)).getexif().get(MAKE) == "PhoneMaker"

    up = ok(post(client, "id_back", raw, headers=t["donor"], name="id.jpg"), 201)
    assert up["claim_token"] is None and up["content_type"] == "image/jpeg"

    r = client.get(up["url"], headers=t["donor"])
    assert r.status_code == 200
    assert MAKE not in Image.open(io.BytesIO(r.content)).getexif()


def test_type_is_decided_by_content_not_filename(files):
    client, _ = files
    assert post(client, "id_front", b"MZ\x90\x00 not an image", name="id.png").status_code == 415
    assert post(client, "id_front", b"", name="id.png").status_code == 400
    # Right magic bytes, broken image -> asks for re-upload (UC-D1 alt 6a)
    assert post(client, "id_front", b"\x89PNG\r\n\x1a\n garbage").status_code == 400


def test_size_limit_and_pdf_served_as_download(files):
    client, t = files
    too_big = b"%PDF-1.4\n" + b"0" * MAX_BYTES
    assert post(client, "legitimacy_document", too_big, name="doc.pdf").status_code == 413

    up = ok(post(client, "legitimacy_document", b"%PDF-1.4\n%%EOF\n", name="doc.pdf"), 201)
    r = client.get(up["url"], headers=t["admin"])
    assert r.status_code == 200 and r.headers["content-disposition"].startswith("attachment")
    assert r.headers["x-content-type-options"] == "nosniff"


def test_public_barangay_qr_needs_the_right_role(files):
    client, t = files
    assert post(client, "barangay_donation_qr", png()).status_code == 401
    assert post(client, "barangay_donation_qr", png(), headers=t["donor"]).status_code == 403
    pdf = b"%PDF-1.4\n%%EOF\n"
    assert post(client, "barangay_donation_qr", pdf, headers=t["brgy"]).status_code == 415

    up = ok(post(client, "barangay_donation_qr", png(), headers=t["brgy"]), 201)
    r = client.get(up["url"])  # donors and guests can see it
    assert r.status_code == 200 and r.headers["content-type"] == "image/png"


def test_unknown_purpose_and_missing_file(files):
    client, _ = files
    assert post(client, "selfie", png()).status_code == 400
    assert client.get("/uploads/00000000-0000-0000-0000-000000000000").status_code == 404


def test_claim_upload_for_registration(files):
    client, t = files
    up = ok(post(client, "id_front", png()), 201)

    db = database.SessionLocal()
    try:
        donor = db.query(User).filter(User.email == "donor.test@example.com").one()
        other = db.query(User).filter(User.email == "cmo.test@example.com").one()
        with pytest.raises(HTTPException):
            claim_upload(db, up["file_id"], "wrong-token", donor, {"id_front"})
        with pytest.raises(HTTPException):  # right token, wrong purpose
            claim_upload(db, up["file_id"], up["claim_token"], donor, {"legitimacy_document"})

        claimed = claim_upload(db, up["file_id"], up["claim_token"], donor, {"id_front"})
        assert claimed.owner_user_id == donor.user_id and claimed.claim_token_hash is None
        with pytest.raises(HTTPException):  # token is single use
            claim_upload(db, up["file_id"], up["claim_token"], other, {"id_front"})
        db.commit()
    finally:
        db.close()

    assert client.get(up["url"], headers=t["donor"]).status_code == 200