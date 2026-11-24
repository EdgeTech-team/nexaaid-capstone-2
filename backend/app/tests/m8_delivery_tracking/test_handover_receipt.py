"""J2 / NF-015 (team agreement Nov 18, 2026, A2): proof of receipt.

Done when (task brief J2):
  - no code = 422, wrong code = 403, 5 wrong = 429, and a correct code is
    refused during the lock
  - no name or signature = 422
  - the code is never sent to the representative's account
Also: the code is shown once, only to CSWS Main Office staff (not the
Administrator), and is never in a notification or the audit log; the
new-code endpoint (CSWS Main Office and the DRRMO user who carried it; 409
unless Delivered); one code and one lock per trip stop, whose receipts share
one signature; the signature and slip photo are the signer's own, of the
right type and size, and never reused; the Acknowledgment Receipt for each
role.
"""
import re
from dataclasses import replace
from datetime import datetime, timedelta, timezone

import core.shared.database as database
from core.shared.uploads import PURPOSES
from core.shared.audit_log_model import AuditLog
from core.m8_delivery_tracking.delivery_model import Delivery, Receipt
from core.notifications.notification_model import Notification
from core.m1_user_management.user_rbac_model import User
from core.m8_delivery_tracking import handover
from tests.receipt_helpers import (
    SIGNER, counts_as_sent, handover_code, image_bytes, upload, upload_signature,
)
from tests.m8_delivery_tracking.test_delivery_trips import _deliver, _stocked, _trip
from tests.m5_inventory.test_pickup_days_and_runs import _activate_everyone
from tests.m1_user_management.test_role_flows import accept_body, api, ok  # noqa: F401  (fixture)
from tests.m7_logistics_support.test_shared_logistics_notifications import _add_user

CODE = "583920"


# ------------------------------------------------------------------ helpers
def _codes(monkeypatch, *codes):
    """The next handover codes the server makes, in this order."""
    it = iter(codes)
    monkeypatch.setattr(handover, "new_code", lambda: next(it))


def _arrived(client, t, rid=None, who="csws"):
    """A delivery of 30 kg rice that reached Barangay Test. Returns its id
    and the response of the step to Delivered (made by [who])."""
    rid = rid if rid is not None else _stocked(client, t)
    did = ok(_deliver(client, t, rid, [{"item_id": 1, "quantity": 30}]), 201)["delivery_id"]
    ok(client.post(f"/deliveries/{did}/advance", headers=t["csws"]))            # In Transit
    return did, ok(client.post(f"/deliveries/{did}/advance", headers=t[who]))   # Delivered


def _body(client, t, did, code, who="brgy"):
    """A complete confirm body: counts as sent, [code], signer, a fresh signature."""
    d = ok(client.get(f"/deliveries/{did}", headers=t[who]))
    return {"items": counts_as_sent(d["items"]), "handover_code": code, **SIGNER,
            "signature_file_id": upload_signature(client, t[who])}


def _confirm(client, t, did, body, who="brgy"):
    return client.post(f"/deliveries/{did}/confirm-receipt", headers=t[who], json=body)


def _status(client, t, did):
    return ok(client.get(f"/deliveries/{did}", headers=t["csws"]))["status"]


def _wrong_rows(ids):
    db = database.SessionLocal()
    try:
        return (db.query(AuditLog)
                .filter(AuditLog.action == handover.WRONG_CODE, AuditLog.entity_id.in_(ids))
                .count())
    finally:
        db.close()


def _age_wrong_rows(minutes):
    """Pretend the wrong codes were typed [minutes] ago."""
    db = database.SessionLocal()
    try:
        (db.query(AuditLog).filter(AuditLog.action == handover.WRONG_CODE)
         .update({AuditLog.timestamp: datetime.now(timezone.utc) - timedelta(minutes=minutes)},
                 synchronize_session=False))
        db.commit()
    finally:
        db.close()


def _rep(client, key, barangay_id=None):
    """Another Barangay Receiving Representative account: assigned to
    [barangay_id], or to no barangay at all."""
    headers = _add_user(client, key, "Barangay Receiving Representative")
    if barangay_id is not None:
        db = database.SessionLocal()
        try:
            (db.query(User).filter(User.email == f"{key}@test.local")
             .update({User.assigned_barangay_id: barangay_id}, synchronize_session=False))
            db.commit()
        finally:
            db.close()
    return headers


def _stop_trip(client, t, quantities=(30, 20)):
    """A started trip with one delivery per quantity, all to Barangay Test."""
    tid = ok(_trip(client, t, [
        {"report_id": _stocked(client, t), "items": [{"item_id": 1, "quantity": q}]}
        for q in quantities
    ]), 201)["trip_id"]
    ok(client.post(f"/trips/{tid}/start", headers=t["csws"]))
    return tid


def _trip_body(client, t, tid, code):
    rows = ok(client.get("/deliveries/", headers=t["brgy"],
                         params={"trip_id": tid, "status": "Delivered"}))
    return {"deliveries": [{"delivery_id": r["delivery_id"], "items": counts_as_sent(r["items"])}
                           for r in rows],
            "handover_code": code, **SIGNER,
            "signature_file_id": upload_signature(client, t["brgy"])}


# ------------------------------------------- the code is for CSWS staff only
def test_the_code_is_shown_once_to_csws_staff_only(api, monkeypatch):
    client, t = api
    _activate_everyone()
    monkeypatch.setattr(handover, "new_code", lambda: CODE)

    did, arrived = _arrived(client, t)
    assert arrived["status"] == "Delivered" and arrived["handover_code"] == CODE
    # The Administrator marking a delivery Arrived gets no code.
    _, by_admin = _arrived(client, t, who="admin")
    assert by_admin["status"] == "Delivered" and "handover_code" not in by_admin

    # Nothing the rep's account can read carries it, before or after confirming.
    for path in ("/deliveries/", f"/deliveries/{did}", f"/deliveries/{did}/history",
                 "/deliveries/counts", "/notifications/", "/dashboard/barangay"):
        r = client.get(path, headers=t["brgy"])
        assert r.status_code == 200, path
        assert CODE not in r.text, path
    done = _confirm(client, t, did, _body(client, t, did, CODE))
    assert done.status_code == 201 and CODE not in done.text
    for path in (f"/deliveries/{did}", f"/deliveries/{did}/history",
                 f"/deliveries/{did}/acknowledgment", "/notifications/"):
        r = client.get(path, headers=t["brgy"])
        assert r.status_code == 200 and CODE not in r.text, path

    # Nor in any notification or audit row, for anyone.
    db = database.SessionLocal()
    try:
        assert all(CODE not in f"{n.title} {n.message}" for n in db.query(Notification))
        assert all(CODE not in f"{a.old_value} {a.new_value}" for a in db.query(AuditLog))
        assert db.get(Delivery, did).handover_code_hash is None    # not kept after confirming
    finally:
        db.close()


def test_a_trip_stop_has_one_code_and_its_receipts_share_one_signature(api, monkeypatch):
    client, t = api
    monkeypatch.setattr(handover, "new_code", lambda: CODE)
    tid = _stop_trip(client, t)
    view = ok(client.post(f"/trips/{tid}/stops/1/arrived", headers=t["csws"]))
    shown = view["handover_code"]
    assert shown["code"] == CODE and len(shown["delivery_ids"]) == 2

    # The Administrator marking a stop arrived gets no code.
    other = _stop_trip(client, t, quantities=(10,))
    assert "handover_code" not in ok(client.post(f"/trips/{other}/stops/1/arrived", headers=t["admin"]))

    url = f"/trips/{tid}/confirm-receipt"
    body = _trip_body(client, t, tid, CODE)
    no_code = {k: v for k, v in body.items() if k != "handover_code"}
    assert client.post(url, headers=t["brgy"], json=no_code).status_code == 422
    assert client.post(url, headers=t["brgy"], json={**body, "handover_code": "111111"}).status_code == 403
    done = ok(client.post(url, headers=t["brgy"], json=body))
    assert sorted(done["confirmed_deliveries"]) == sorted(shown["delivery_ids"])

    db = database.SessionLocal()
    try:
        receipts = db.query(Receipt).filter(Receipt.delivery_id.in_(shown["delivery_ids"])).all()
        assert len(receipts) == 2
        assert {r.signature_file_id for r in receipts} == {body["signature_file_id"]}
        assert all(r.handover_verified and r.signer_name == SIGNER["signer_name"]
                   and len(r.items) == 1 for r in receipts)
    finally:
        db.close()


# ------------------------------------------------ Done when: 422, 403, 429
def test_no_code_is_422_and_a_wrong_code_is_403(api, monkeypatch):
    client, t = api
    _codes(monkeypatch, "123456")
    did, arrived = _arrived(client, t)
    body = _body(client, t, did, "123456")

    no_code = {k: v for k, v in body.items() if k != "handover_code"}
    assert _confirm(client, t, did, no_code).status_code == 422
    for bad in ("12345", "1234567", "12a456", "１２３４５６"):
        assert _confirm(client, t, did, {**body, "handover_code": bad}).status_code == 422, bad
    assert _wrong_rows([did]) == 0                          # a malformed code is not a try

    r = _confirm(client, t, did, {**body, "handover_code": "999999"})
    assert r.status_code == 403 and "not correct" in r.json()["detail"]
    assert _wrong_rows([did]) == 1                          # kept although the request failed
    assert _status(client, t, did) == "Delivered"
    ok(_confirm(client, t, did, body), 201)


def test_five_wrong_codes_lock_confirmation_for_15_minutes(api, monkeypatch):
    client, t = api
    _codes(monkeypatch, "123456", "654321")                 # arrival, then a new code
    did, arrived = _arrived(client, t)
    assert arrived["handover_code"] == "123456"
    body = _body(client, t, did, "123456")
    wrong = {**body, "handover_code": "999999"}

    for i in range(4):
        assert _confirm(client, t, did, wrong).status_code == 403, i
    r = _confirm(client, t, did, wrong)                     # the fifth wrong try
    assert r.status_code == 429 and int(r.headers["Retry-After"]) > 0

    assert _confirm(client, t, did, body).status_code == 429             # the right code too
    # Any account: another rep of the same barangay is locked out too.
    other_rep = _rep(client, "brgy1b", barangay_id=1)
    other_body = {**body, "signature_file_id": upload_signature(client, other_rep)}
    assert client.post(f"/deliveries/{did}/confirm-receipt", headers=other_rep,
                       json=other_body).status_code == 429
    assert handover_code(client, did) == "654321"                        # a new code ...
    assert _confirm(client, t, did, {**body, "handover_code": "654321"}).status_code == 429  # ... no reset
    assert _status(client, t, did) == "Delivered" and _wrong_rows([did]) == 5

    _age_wrong_rows(16)                                     # 15 minutes later
    ok(_confirm(client, t, did, {**body, "handover_code": "654321"}), 201)


def test_the_lock_covers_every_delivery_of_a_trip_stop(api, monkeypatch):
    client, t = api
    monkeypatch.setattr(handover, "new_code", lambda: CODE)
    tid = _stop_trip(client, t)
    first_id, second_id = ok(client.post(f"/trips/{tid}/stops/1/arrived",
                                         headers=t["csws"]))["handover_code"]["delivery_ids"]

    for _ in range(4):
        assert _confirm(client, t, first_id, _body(client, t, first_id, "111111")).status_code == 403
    # The fifth wrong try, on the other delivery of the same stop: locked.
    assert _confirm(client, t, second_id, _body(client, t, second_id, "111111")).status_code == 429
    trip_body = _trip_body(client, t, tid, CODE)
    assert client.post(f"/trips/{tid}/confirm-receipt", headers=t["brgy"],
                       json=trip_body).status_code == 429

    # A delivery on its own has its own lock.
    did, _ = _arrived(client, t)
    ok(_confirm(client, t, did, _body(client, t, did, CODE)), 201)


# ------------------------------------ Done when: name and signature are required
def test_name_position_and_signature_are_required(api):
    client, t = api
    did, arrived = _arrived(client, t)
    body = _body(client, t, did, arrived["handover_code"])

    for field in ("signer_name", "signer_position", "signature_file_id"):
        r = _confirm(client, t, did, {k: v for k, v in body.items() if k != field})
        assert r.status_code == 422, field
    for blank in ("", "   ", "A"):
        assert _confirm(client, t, did, {**body, "signer_name": blank}).status_code == 422, blank
    assert _confirm(client, t, did, {**body, "signer_position": "  "}).status_code == 422
    assert _status(client, t, did) == "Delivered" and _wrong_rows([did]) == 0

    receipt = ok(_confirm(client, t, did, body), 201)["receipt"]
    assert (receipt["signer_name"], receipt["signer_position"], receipt["handover_verified"]) == (
        SIGNER["signer_name"], SIGNER["signer_position"], True)
    assert re.fullmatch(r"AR-\d{4}-\d{6}", receipt["reference_no"])


def test_signature_and_slip_photo_files_are_checked(api, monkeypatch):
    client, t = api
    did, arrived = _arrived(client, t)
    body = _body(client, t, did, arrived["handover_code"])

    # Not the signer's own (the Administrator's upload), an unknown id, and a
    # slip photo sent as the signature: refused.
    r = _confirm(client, t, did, {**body, "signature_file_id": upload_signature(client, t["admin"])})
    assert r.status_code == 422 and "not found" in r.json()["detail"]
    assert _confirm(client, t, did, {**body, "signature_file_id": "no-such-file"}).status_code == 422
    slip = upload(client, t["brgy"], "receipt_slip_photo", image_bytes("JPEG"), "slip.jpg")
    assert slip.status_code == 201, slip.text
    slip_id = slip.json()["file_id"]
    assert _confirm(client, t, did, {**body, "signature_file_id": slip_id}).status_code == 422

    # Checked by the first bytes, not the name: a JPEG is not a signature,
    # a PDF is not a slip photo. A slip photo is at most 1 MB.
    assert upload(client, t["brgy"], "receipt_signature", image_bytes("JPEG"),
                  "signature.png").status_code == 415
    assert upload(client, t["brgy"], "receipt_slip_photo", b"%PDF-1.4 test",
                  "slip.jpg").status_code == 415
    # The size cap per purpose: the real limits, then the check itself with
    # a small cap (how big a re-encoded photo is depends on Pillow).
    assert PURPOSES["receipt_slip_photo"].max_bytes == 1024 * 1024
    assert PURPOSES["receipt_signature"].max_bytes == 300 * 1024
    monkeypatch.setitem(PURPOSES, "receipt_slip_photo",
                        replace(PURPOSES["receipt_slip_photo"], max_bytes=50 * 1024))
    big = upload(client, t["brgy"], "receipt_slip_photo",
                 image_bytes("JPEG", size=(400, 400), noise=True, quality=90), "slip.jpg")
    assert big.status_code == 413 and "50 KB" in big.json()["detail"]
    monkeypatch.undo()   # back to the real 1 MB cap for the rest of the test
    # Only the people who confirm upload these.
    for who in ("donor", "csws"):
        assert upload(client, t[who], "receipt_signature", image_bytes("PNG"),
                      "signature.png").status_code == 403, who

    ok(_confirm(client, t, did, {**body, "slip_photo_file_id": slip_id}), 201)

    # Used once: refused on the next receipt.
    did2, arrived2 = _arrived(client, t)
    body2 = _body(client, t, did2, arrived2["handover_code"])
    r = _confirm(client, t, did2, {**body2, "signature_file_id": body["signature_file_id"]})
    assert r.status_code == 422 and "already used" in r.json()["detail"]
    r = _confirm(client, t, did2, {**body2, "slip_photo_file_id": slip_id})
    assert r.status_code == 422 and "already used" in r.json()["detail"]
    ok(_confirm(client, t, did2, body2), 201)


# ----------------------------------------------------- the new-code endpoint
def test_the_new_code_endpoint(api, monkeypatch):
    client, t = api
    _codes(monkeypatch, "111111", "222222")
    rid = _stocked(client, t)
    waiting = ok(_deliver(client, t, rid, [{"item_id": 1, "quantity": 5}]), 201)["delivery_id"]
    assert client.post(f"/deliveries/{waiting}/handover-code",
                       headers=t["csws"]).status_code == 409          # not arrived yet

    did, arrived = _arrived(client, t, rid)
    assert arrived["handover_code"] == "111111"
    url = f"/deliveries/{did}/handover-code"
    for who in ("brgy", "admin", "unit", "donor", "drrmo"):
        assert client.post(url, headers=t[who]).status_code == 403, who
    new = ok(client.post(url, headers=t["csws"]))
    assert new["delivery_ids"] == [did] and new["handover_code"] == "222222" and new["created_at"]

    body = _body(client, t, did, "111111")
    assert _confirm(client, t, did, body).status_code == 403       # the old code stopped working
    ok(_confirm(client, t, did, {**body, "handover_code": "222222"}), 201)
    assert client.post(url, headers=t["csws"]).status_code == 409  # Confirmed


def test_the_drrmo_user_who_carried_it_gets_a_code(api):
    client, t = api
    drrmo2 = _add_user(client, "drrmo2", "DRRMO Logistics Support")
    did = ok(_deliver(client, t, _stocked(client, t), [{"item_id": 1, "quantity": 30}]), 201)["delivery_id"]
    req = ok(client.post("/logistics/requests", headers=t["csws"],
                         json={"delivery_id": did, "trucks": 1}), 201)["request_id"]
    ok(client.patch(f"/drrmo/requests/{req}/accept", headers=t["drrmo"], json=accept_body()))
    ok(client.post(f"/drrmo/requests/{req}/picked-up", headers=t["drrmo"]))
    assert ok(client.post(f"/drrmo/requests/{req}/delivered",
                          headers=t["drrmo"]))["delivery_status"] == "Delivered"

    url = f"/deliveries/{did}/handover-code"
    assert client.post(url, headers=drrmo2).status_code == 403     # not the one who carried it
    code = ok(client.post(url, headers=t["drrmo"]))["handover_code"]
    ok(_confirm(client, t, did, _body(client, t, did, code)), 201)


# ------------------------------------------- the Acknowledgment Receipt
def test_the_acknowledgment_receipt_for_each_role(api):
    client, t = api
    other_donor = _add_user(client, "donor2", "Individual Donor")
    rid = _stocked(client, t)                               # the test donor's rice
    did, arrived = _arrived(client, t, rid)
    url = f"/deliveries/{did}/acknowledgment"
    assert client.get(url, headers=t["csws"]).status_code == 404     # not confirmed yet

    body = _body(client, t, did, arrived["handover_code"])
    slip_id = upload(client, t["brgy"], "receipt_slip_photo", image_bytes("JPEG"),
                     "slip.jpg").json()["file_id"]
    ok(_confirm(client, t, did, {**body, "slip_photo_file_id": slip_id, "remarks": "Complete"}), 201)

    # Full view: CSWS Main Office, Disaster Unit, Administrator, the rep.
    for who in ("csws", "unit", "admin", "brgy"):
        a = ok(client.get(url, headers=t[who]))
        assert a["view"] == "full", who
        assert re.fullmatch(r"AR-\d{4}-\d{6}", a["reference_no"])
        assert (a["delivery_id"], a["barangay_name"], a["report_id"]) == (did, "Barangay Test", rid)
        assert (a["signer_name"], a["signer_position"]) == (SIGNER["signer_name"], SIGNER["signer_position"])
        assert a["handover_verified"] is True and a["remarks"] == "Complete" and a["received_at"]
        line = a["items"][0]
        assert (line["item_name"], line["unit"], line["packaging"]) == ("Rice", "kg", "Sack (50 kg)")
        assert (line["expected_quantity"], line["received_quantity"]) == (30, 30)
        sig = client.get(a["signature_url"], headers=t[who])
        assert sig.status_code == 200 and sig.headers["content-type"] == "image/png"
        assert sig.content.startswith(b"\x89PNG")
        photo = client.get(a["slip_photo_url"], headers=t[who])
        assert photo.status_code == 200 and photo.headers["content-type"] == "image/jpeg"

    # Donor view: the donor whose rice was on it sees items, barangay,
    # reference no. and date; no signer, signature, report or remarks.
    d = ok(client.get(url, headers=t["donor"]))
    assert d["view"] == "donor"
    assert set(d) == {"view", "reference_no", "delivery_id", "barangay_name", "received_at", "items"}
    assert set(d["items"][0]) == {"item_id", "item_name", "unit", "packaging", "expected_quantity",
                                  "received_quantity", "discrepancy_reason"}
    assert SIGNER["signer_name"] not in str(d) and "Complete" not in str(d)
    for path in ("signature", "slip-photo"):
        assert client.get(f"{url}/{path}", headers=t["donor"]).status_code == 403

    # Everyone else: refused.
    assert client.get(url, headers=other_donor).status_code == 403   # a donor not linked
    assert client.get(url, headers=t["drrmo"]).status_code == 403
    assert client.get(url, headers=t["cmo"]).status_code == 403
    assert client.get(url, headers=t["brgy2"]).status_code == 404    # another barangay


# ------------------------------- J4 / G-001: only the Barangay Rep confirms
def test_only_the_barangay_rep_confirms_and_acknowledges(api):
    """UC-B1 actor (task brief J4): Administrator = 403; a rep of another
    barangay = 403; a rep with no assigned barangay = 403. The Administrator
    can still read the Acknowledgment Receipt."""
    client, t = api
    no_barangay = _rep(client, "brgy0")
    did, arrived = _arrived(client, t)
    body = _body(client, t, did, arrived["handover_code"])
    url = f"/deliveries/{did}/confirm-receipt"

    assert client.post(url, headers=t["admin"], json=body).status_code == 403
    r = client.post(url, headers=t["brgy2"], json=body)
    assert r.status_code == 403 and "not for your assigned barangay" in r.json()["detail"]
    r = client.post(url, headers=no_barangay, json=body)
    assert r.status_code == 403 and "no assigned barangay" in r.json()["detail"]
    # Refused before the code was looked at, and nothing was saved.
    assert _wrong_rows([did]) == 0 and _status(client, t, did) == "Delivered"
    ok(_confirm(client, t, did, body), 201)                 # the rep of that barangay

    ack = f"/deliveries/{did}/acknowledge"
    assert client.post(ack, headers=t["admin"]).status_code == 403
    r = client.post(ack, headers=t["brgy2"])
    assert r.status_code == 403 and "not for your assigned barangay" in r.json()["detail"]
    r = client.post(ack, headers=no_barangay)
    assert r.status_code == 403 and "no assigned barangay" in r.json()["detail"]
    assert client.post(ack, headers=t["brgy"]).status_code == 409   # the receipt already acknowledged it

    # The Administrator still views the receipt and its signature.
    a = ok(client.get(f"/deliveries/{did}/acknowledgment", headers=t["admin"]))
    assert a["view"] == "full" and a["signer_name"] == SIGNER["signer_name"]
    assert client.get(a["signature_url"], headers=t["admin"]).status_code == 200


def test_only_the_barangay_rep_confirms_a_trip_stop(api, monkeypatch):
    client, t = api
    monkeypatch.setattr(handover, "new_code", lambda: CODE)
    no_barangay = _rep(client, "brgy0")
    tid = _stop_trip(client, t)
    ok(client.post(f"/trips/{tid}/stops/1/arrived", headers=t["csws"]))
    body = _trip_body(client, t, tid, CODE)
    url = f"/trips/{tid}/confirm-receipt"

    assert client.post(url, headers=t["admin"], json=body).status_code == 403
    r = client.post(url, headers=t["brgy2"], json=body)       # no stop at Barangay Two
    assert r.status_code == 403 and "assigned barangay" in r.json()["detail"]
    r = client.post(url, headers=no_barangay, json=body)
    assert r.status_code == 403 and "no assigned barangay" in r.json()["detail"]
    assert _wrong_rows(body_ids := [d["delivery_id"] for d in body["deliveries"]]) == 0
    done = ok(client.post(url, headers=t["brgy"], json=body))
    assert sorted(done["confirmed_deliveries"]) == sorted(body_ids)
