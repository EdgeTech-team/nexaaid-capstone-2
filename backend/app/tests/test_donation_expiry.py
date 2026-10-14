"""
Termination of donations that are never handed over (services/donation_expiry.py,
team decision Oct 9, 2026; an addition to manuscript 3.2).

  Drop Off      expires 14 days after it was submitted
  Door to Door  expires 7 days after the preferred pickup time
  reminder      once, 3 days before the deadline
  Cancelled     by the donor (account or guest phone number) or CSWS
  Reinstate     CSWS reopens it with a fresh deadline (UC-CM1 alt 2a)

Nothing is deleted, and received goods / inventory are never touched.
"""
from datetime import datetime, timedelta, timezone

import core.database as database
from models.notification import Notification
from models.physical_donation_model import PhysicalDonation
from services.donation_expiry import entry_status, expire_overdue, utc
from tests.test_donation_batch import LINE, _pickup_slot, _report
from tests.test_inventory_paths import _stock
from tests.test_role_flows import api, ok  # noqa: F401  (fixture)

UTC = timezone.utc


def _entry(client, headers, rid, n=1, **extra):
    body = {"report_id": rid, "handover_method": "Drop Off",
            "items": [dict(LINE) for _ in range(n)], **extra}
    return ok(client.post("/donations/batch", headers=headers, json=body), 201)


def _rows(ref):
    db = database.SessionLocal()
    try:
        return (db.query(PhysicalDonation).filter(PhysicalDonation.batch_reference == ref)
                .order_by(PhysicalDonation.donation_id).all())
    finally:
        db.close()


def _age(ref, days):
    """Pretend the donation was submitted `days` ago (moves its deadline too)."""
    db = database.SessionLocal()
    try:
        for r in db.query(PhysicalDonation).filter(PhysicalDonation.batch_reference == ref):
            r.created_at = utc(r.created_at) - timedelta(days=days)
            r.expires_at = utc(r.expires_at) - timedelta(days=days)
        db.commit()
    finally:
        db.close()


def _notes(user_email, kind):
    db = database.SessionLocal()
    try:
        from models.user_rbac_model import User
        uid = db.query(User).filter(User.email == user_email).one().user_id
        return db.query(Notification).filter(Notification.user_id == uid, Notification.type == kind).count()
    finally:
        db.close()


DONOR = "donor.test@example.com"


def _activate(email):
    """SQLite keeps the server default is_active='true' as text, which the
    role lookup for notifications does not match. Postgres is fine."""
    db = database.SessionLocal()
    try:
        from models.user_rbac_model import User
        db.query(User).filter(User.email == email).update({"is_active": True})
        db.commit()
    finally:
        db.close()


def test_new_donations_get_a_deadline(api):
    client, t = api
    rid = _report(client, t)
    drop = _entry(client, t["donor"], rid)
    assert drop["status"] == "Pending" and drop["days_left"] in (13, 14)
    created = utc(_rows(drop["batch_reference"])[0].created_at)
    assert abs((utc(_rows(drop["batch_reference"])[0].expires_at) - created) - timedelta(days=14)) < timedelta(minutes=5)

    slot = _pickup_slot()
    door = _entry(client, t["donor"], rid, handover_method="Door to Door",
                  pickup_address="1 Test St", preferred_pickup_at=slot.isoformat())
    assert utc(_rows(door["batch_reference"])[0].expires_at) == slot.astimezone(UTC) + timedelta(days=7)

    rules = ok(client.get("/donations/expiry-rules"))
    assert rules["drop_off_days"] == 14 and rules["pickup_grace_days"] == 7
    assert "14 days" in rules["drop_off_label"] and rules["cancel_reasons"]


def test_overdue_drop_off_expires_and_leaves_pending_lists(api):
    client, t = api
    rid = _report(client, t)
    old = _entry(client, t["donor"], rid, n=2)
    fresh = _entry(client, t["donor"], rid)
    _age(old["batch_reference"], 15)

    # Any pending screen runs the check; the overdue one is gone from it.
    pending = ok(client.get("/donations/entries?pending_only=true", headers=t["csws"]))
    refs = [e["batch_reference"] for r in pending["reports"] for e in r["entries"]]
    assert refs == [fresh["batch_reference"]]
    assert all(r.status == "Expired" for r in _rows(old["batch_reference"]))
    row = _rows(old["batch_reference"])[0]
    assert row.closed_by_user_id is None and row.close_reason.startswith("Not brought to the CSWS office by")

    # Not deleted: it is in the Closed tab, and the donor sees it with the reason.
    closed = ok(client.get("/donations/records?status=Closed", headers=t["csws"]))
    assert [e["batch_reference"] for e in closed] == [old["batch_reference"]]
    assert closed[0]["status"] == "Expired" and closed[0]["closed_by_system"] is True
    everyday = ok(client.get("/donations/records", headers=t["csws"]))
    assert old["batch_reference"] not in [e["batch_reference"] for e in everyday]
    mine = ok(client.get("/donations/mine", headers=t["donor"]))
    assert mine["summary"]["expired"] == 2 and mine["summary"]["pending"] == 1
    assert _notes(DONOR, "donation_expired") == 1

    # Running it again changes nothing and sends nothing new.
    assert ok(client.post("/donations/expiry/run", headers=t["csws"]))["expired_entries"] == 0
    assert _notes(DONOR, "donation_expired") == 1


def test_partly_received_only_expires_what_is_still_pending(api):
    client, t = api
    rid = _report(client, t)
    e = _entry(client, t["donor"], rid, n=2)
    first = e["items"][0]["donation_id"]
    ok(client.post("/donations/receive", headers=t["csws"],
                   json={"donation_id": first, "actual_quantity": 2}))
    _age(e["batch_reference"], 20)
    ok(client.post("/donations/expiry/run", headers=t["csws"]))

    assert [r.status for r in _rows(e["batch_reference"])] == ["Received", "Expired"]
    assert _stock(1, rid) == 2                       # inventory untouched
    found = ok(client.get(f"/donations/by-batch/{e['batch_reference']}", headers=t["csws"]))
    assert found["status"] == "Received" and found["closed_items"] == 1


def test_reminder_is_sent_once_before_the_deadline(api):
    client, t = api
    rid = _report(client, t)
    e = _entry(client, t["donor"], rid)
    _age(e["batch_reference"], 12)                   # 2 days left
    ok(client.post("/donations/expiry/run", headers=t["csws"]))
    ok(client.post("/donations/expiry/run", headers=t["csws"]))
    assert _notes(DONOR, "donation_expiring_soon") == 1
    assert _rows(e["batch_reference"])[0].status == "Pending"
    dash = ok(client.get("/dashboard/csws-main", headers=t["csws"]))
    assert dash["due_soon_donations"] == 1 and dash["expired_donations"] == 0


def test_door_to_door_expires_after_the_pickup_window(api):
    client, t = api
    rid = _report(client, t)
    e = _entry(client, t["donor"], rid, handover_method="Door to Door",
               pickup_address="1 Test St", preferred_pickup_at=_pickup_slot().isoformat())
    assert ok(client.get("/donations/pickups", headers=t["csws"]))[0]["expires_label"]
    db = database.SessionLocal()
    try:
        late = datetime.now(UTC) + timedelta(days=60)
        assert expire_overdue(db, now=late)["expired_entries"] == 1
        db.commit()
    finally:
        db.close()
    assert ok(client.get("/donations/pickups", headers=t["csws"])) == []
    assert _rows(e["batch_reference"])[0].close_reason.startswith("Not collected by")


def test_donor_cancels_own_pending_donation(api):
    client, t = api
    _activate("csws.test@example.com")
    rid = _report(client, t)
    e = _entry(client, t["donor"], rid, n=2)
    ref = e["batch_reference"]
    first = e["items"][0]["donation_id"]
    ok(client.post("/donations/receive", headers=t["csws"],
                   json={"donation_id": first, "actual_quantity": 2}))

    # Someone else's account cannot cancel it; no login and no phone: 401.
    assert client.post(f"/donations/entries/{ref}/cancel", headers=t["unit"], json={}).status_code == 403
    assert client.post(f"/donations/entries/{ref}/cancel", json={}).status_code == 401

    out = ok(client.post(f"/donations/entries/{ref.lower()}/cancel", headers=t["donor"],
                         json={"reason": "I gave the items another way"}))
    assert out["changed_items"] == 1 and out["status"] == "Received"   # received item stays
    assert [r.status for r in _rows(ref)] == ["Received", "Cancelled"]
    assert _rows(ref)[1].close_reason == "I gave the items another way"
    assert _notes("csws.test@example.com", "donation_cancelled") == 1

    again = client.post(f"/donations/entries/{ref}/cancel", headers=t["donor"], json={})
    assert again.status_code == 409


def test_guest_cancels_with_their_phone_number(api):
    client, t = api
    rid = _report(client, t)
    e = _entry(client, {}, rid, guest_donor={"full_name": "Guest", "contact_number": "0917 123 4567"})
    ref = e["batch_reference"]
    wrong = client.post(f"/donations/entries/{ref}/cancel", json={"contact_number": "09181234567"})
    assert wrong.status_code == 403
    ok(client.post(f"/donations/entries/{ref}/cancel", json={"contact_number": "+63 917-123-4567"}))
    assert _rows(ref)[0].status == "Cancelled" and _rows(ref)[0].closed_by_user_id is None


def test_csws_reinstates_a_late_donation_and_receives_it(api):
    client, t = api
    rid = _report(client, t)
    e = _entry(client, t["donor"], rid)
    ref = e["batch_reference"]
    donation_id = e["items"][0]["donation_id"]
    _age(ref, 15)
    ok(client.post("/donations/expiry/run", headers=t["csws"]))

    # Receiving an expired donation explains what to do instead of a code.
    r = client.post("/donations/receive", headers=t["csws"],
                    json={"donation_id": donation_id, "actual_quantity": 2})
    assert r.status_code == 400 and "Reinstate" in r.json()["detail"]

    assert client.post(f"/donations/entries/{ref}/reinstate", headers=t["donor"], json={}).status_code == 403
    out = ok(client.post(f"/donations/entries/{ref}/reinstate", headers=t["csws"],
                         json={"note": "Donor arrived late with the QR"}))
    assert out["status"] == "Pending" and out["expires_label"]
    row = _rows(ref)[0]
    assert row.closed_at is None and row.close_reason is None
    assert utc(row.expires_at) > datetime.now(UTC) + timedelta(days=13)
    assert _notes(DONOR, "donation_reinstated") == 1

    ok(client.post("/donations/receive", headers=t["csws"],
                   json={"donation_id": donation_id, "actual_quantity": 2}))
    assert _stock(1, rid) == 2
    assert client.post(f"/donations/entries/{ref}/reinstate", headers=t["csws"], json={}).status_code == 409


def test_expiry_run_needs_staff_or_cron_token(api, monkeypatch):
    client, t = api
    assert client.post("/donations/expiry/run", headers=t["donor"]).status_code == 403
    assert client.post("/donations/expiry/run").status_code == 403
    monkeypatch.setenv("DONATION_CRON_TOKEN", "s3cret")
    assert client.post("/donations/expiry/run", headers={"X-Cron-Token": "nope"}).status_code == 403
    ok(client.post("/donations/expiry/run", headers={"X-Cron-Token": "s3cret"}))


def test_deadlines_come_from_env(api, monkeypatch):
    client, t = api
    monkeypatch.setenv("DONATION_DROPOFF_DAYS", "5")
    rid = _report(client, t)
    e = _entry(client, t["donor"], rid)
    assert e["days_left"] in (4, 5)
    assert "5 days" in ok(client.get("/donations/expiry-rules"))["drop_off_label"]


def test_entry_status_with_closed_items():
    assert entry_status(["Expired", "Expired"]) == "Expired"
    assert entry_status(["Cancelled"]) == "Cancelled"
    assert entry_status(["Expired", "Cancelled"]) == "Expired"
    assert entry_status(["Received", "Expired"]) == "Received"
    assert entry_status(["Pending", "Received", "Cancelled"]) == "Partly Received"
    assert entry_status(["Pending", "Pending"]) == "Pending"
