"""
F-14: uploads made before login (registration ID photos and organization
documents) are deleted once they can no longer be claimed, and new ones are
refused while too many are waiting. Uploads with an owner are never touched.
"""
from datetime import datetime, timedelta, timezone

import core.database as database
from core.storage import get_storage
from models.upload_model import Upload, UploadBlob
from tests.test_role_flows import api, ok  # noqa: F401  (fixture)
from tests.test_uploads import files, png, post  # noqa: F401  (fixture)


def _age(file_id, hours):
    db = database.SessionLocal()
    try:
        up = db.query(Upload).filter(Upload.file_id == file_id).one()
        up.created_at = datetime.now(timezone.utc) - timedelta(hours=hours)
        db.commit()
    finally:
        db.close()


def _row(file_id):
    db = database.SessionLocal()
    try:
        up = db.query(Upload).filter(Upload.file_id == file_id).first()
        return None if up is None else (up.upload_id, up.storage_key)
    finally:
        db.close()


def _has_blob(upload_id):
    db = database.SessionLocal()
    try:
        return db.get(UploadBlob, upload_id) is not None
    finally:
        db.close()


def test_unclaimed_uploads_are_deleted_once_they_can_no_longer_be_claimed(files):
    client, t = files
    old = ok(post(client, "id_front", png()), 201)        # abandoned registration
    waiting = ok(post(client, "id_back", png()), 201)     # still claimable
    mine = ok(post(client, "id_front", png(), headers=t["donor"]), 201)  # has an owner
    _age(old["file_id"], 26)
    _age(waiting["file_id"], 23)
    _age(mine["file_id"], 26)
    old_id, old_key = _row(old["file_id"])

    ok(post(client, "legitimacy_document", png()), 201)  # an upload before login runs the purge

    assert _row(old["file_id"]) is None
    assert not _has_blob(old_id)
    assert not get_storage().path(old_key).exists()
    assert client.get(old["url"], headers=t["admin"]).status_code == 404
    assert client.get(waiting["url"], headers=t["admin"]).status_code == 200
    assert client.get(mine["url"], headers=t["donor"]).status_code == 200


def test_the_donation_expiry_job_also_cleans_up(files):
    client, t = files
    old = ok(post(client, "id_front", png()), 201)
    _age(old["file_id"], 26)
    res = ok(client.post("/donations/expiry/run", headers=t["csws"]))
    assert res["purged_uploads"] == 1
    assert _row(old["file_id"]) is None


def test_uploads_before_login_stop_at_the_cap(files, monkeypatch):
    client, t = files
    first = ok(post(client, "id_front", png()), 201)
    monkeypatch.setattr("api.v1.upload_routes.MAX_UNCLAIMED_BYTES", first["size_bytes"] + 1)

    r = post(client, "id_back", png())
    assert r.status_code == 503 and r.headers["Retry-After"] == "600"
    ok(post(client, "id_back", png(), headers=t["donor"]), 201)  # logged in: no cap

    _age(first["file_id"], 26)
    ok(post(client, "id_back", png()), 201)                      # the purge freed the space
