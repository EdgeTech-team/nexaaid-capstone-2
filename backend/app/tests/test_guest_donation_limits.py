"""NF-004: guest Door to Door follows GUEST_DOOR_TO_DOOR (blocked by default,
or limited to one pickup per number), and NF-005 (D2) limits on guest
donations (anti-flooding). Logged-in donors are not affected.
Rules and numbers: services/guest_limits.py."""
from datetime import datetime, timedelta, timezone

import pytest

import core.auth as auth
import core.database as database
from models.notification import Notification
from models.physical_donation_model import PhysicalDonation
from services.guest_limits import GUEST_DOOR_TO_DOOR_BLOCKED, GUEST_ONE_PICKUP
from tests.test_donation_batch import LINE, _report
from tests.test_pickup_days_and_runs import _activate_everyone, _door
from tests.test_role_flows import api, ok  # noqa: F401  (fixture)



def _guest(phone="0917 555 0001", name="Gina Guest"):
    return {"full_name": name, "contact_number": phone, "consent": True}


def _drop(rid, phone="0917 555 0001", items=None, **extra):
    return {"report_id": rid, "handover_method": "Drop Off", "items": items or [LINE],
            "guest_donor": _guest(phone), **extra}


def _post(client, body, ip="203.0.113.10", headers=None):
    return client.post("/donations/batch", json=body,
                       headers={**(headers or {}), "X-Test-Client": ip})


@pytest.fixture(autouse=True)
def _client_ip_from_test_header(monkeypatch):
    """The per-connection limit reads request.client.host (set from
    X-Forwarded-For by core/client_ip.py in production). TestClient always
    connects from "testclient", so tests name the address in a header."""
    import api.v1.donation_routes as routes
    monkeypatch.setattr(routes, "_client_ip",
                        lambda request: request.headers.get("X-Test-Client", "testclient"))


def _count_rows():
    db = database.SessionLocal()
    try:
        return db.query(PhysicalDonation).count()
    finally:
        db.close()


# --------------------------------------------------------------------------
# NF-004: guest Door to Door follows GUEST_DOOR_TO_DOOR (blocked by default)
# --------------------------------------------------------------------------
def test_blocked_by_default_guest_door_to_door_is_refused(api):
    client, t = api
    rid = _report(client, t)
    assert ok(client.get("/donations/pickup-rules"))["guest_door_to_door"] == "blocked"
    r = _post(client, {**_door(rid, [3]), "guest_donor": _guest()})
    assert r.status_code == 422 and r.json()["detail"] == GUEST_DOOR_TO_DOOR_BLOCKED
    single = {"report_id": rid, "item_id": 1, "packaging": "Box", "quantity": 2,
              "handover_method": "Door to Door", "pickup_address": "Mandaue City Hall, Mandaue City",
              "pickup_days": [3], "guest_donor": _guest()}
    assert client.post("/donations/", json=single).status_code == 422
    assert _count_rows() == 0


def test_guest_drop_off_is_accepted(api):
    client, t = api
    rid = _report(client, t)
    b = ok(_post(client, _drop(rid)), 201)
    assert b["handover_method"] == "Drop Off" and b["status"] == "Pending"


def test_limited_guest_may_ask_for_one_pickup_at_a_time(api, monkeypatch):
    client, t = api
    monkeypatch.setenv("GUEST_DOOR_TO_DOOR", "limited")
    assert ok(client.get("/donations/pickup-rules"))["guest_door_to_door"] == "limited"
    rid, rid2 = _report(client, t), _report(client, t)
    first = ok(_post(client, {**_door(rid, [3]), "guest_donor": _guest()}, ip="198.51.100.1"), 201)
    board = {x["batch_reference"] for x in ok(client.get("/donations/pickups", headers=t["csws"]))}
    assert first["batch_reference"] in board
    r = _post(client, {**_door(rid2, [4]), "guest_donor": _guest(phone="+63 917 555 0001")},
              ip="198.51.100.2")
    assert r.status_code == 429 and r.json()["detail"] == GUEST_ONE_PICKUP
    ok(_post(client, _drop(rid2), ip="198.51.100.4"), 201)           # Drop Off still works
    ok(client.post("/donations/receive", headers=t["csws"],
                   json={"donation_id": first["items"][0]["donation_id"], "actual_quantity": 2}))
    ok(_post(client, {**_door(_report(client, t), [3]), "guest_donor": _guest()},
             ip="198.51.100.5"), 201)                                  # collected: another one


def test_unknown_setting_counts_as_blocked(api, monkeypatch):
    client, t = api
    monkeypatch.setenv("GUEST_DOOR_TO_DOOR", "maybe")
    r = _post(client, {**_door(_report(client, t), [3]), "guest_donor": _guest()})
    assert r.status_code == 422


def test_logged_in_donor_may_ask_for_more_pickups(api):
    client, t = api
    for days in ([3], [4]):
        ok(client.post("/donations/batch", headers=t["donor"],
                       json=_door(_report(client, t), days)), 201)


# --------------------------------------------------------------------------
# D2: limits on guest donations
# --------------------------------------------------------------------------
def test_third_open_entry_for_one_number_is_refused(api):
    client, t = api
    rid, rid2, rid3 = _report(client, t), _report(client, t), _report(client, t)
    ok(_post(client, _drop(rid), ip="198.51.100.1"), 201)
    # Same number written another way: it is normalized first.
    ok(_post(client, _drop(rid2, phone="+63 917-555-0001"), ip="198.51.100.2"), 201)
    r = _post(client, _drop(rid3), ip="198.51.100.3")
    assert r.status_code == 429
    assert r.json()["detail"] == ("You already have 2 donations waiting. "
                                  "Bring them to CSWS first, or sign in.")
    # Another number is not affected.
    ok(_post(client, _drop(rid3, phone="0917 555 0002"), ip="198.51.100.4"), 201)


def test_received_entries_no_longer_count_as_open(api):
    client, t = api
    rids = [_report(client, t) for _ in range(3)]
    first = ok(_post(client, _drop(rids[0]), ip="198.51.100.1"), 201)
    ok(_post(client, _drop(rids[1]), ip="198.51.100.2"), 201)
    ok(client.post("/donations/receive", headers=t["csws"],
                   json={"donation_id": first["items"][0]["donation_id"], "actual_quantity": 2}))
    ok(_post(client, _drop(rids[2]), ip="198.51.100.3"), 201)


def test_sixth_guest_submission_from_one_connection_in_an_hour(api, monkeypatch):
    client, t = api
    rid = _report(client, t)
    clock = [1000.0]
    monkeypatch.setattr(auth, "_now", lambda: clock[0])
    for n in range(5):
        # Different numbers and reports, so only the connection limit applies.
        ok(_post(client, _drop(_report(client, t), phone=f"0917 555 01{n:02d}")), 201)
    r = _post(client, _drop(rid, phone="0917 555 0199"))
    assert r.status_code == 429 and "Retry-After" in r.headers
    # Another connection is not affected...
    ok(_post(client, _drop(rid, phone="0917 555 0199"), ip="203.0.113.99"), 201)
    # ...and an hour later this one may send again.
    clock[0] += 3601
    ok(_post(client, _drop(_report(client, t), phone="0917 555 0198")), 201)


def test_same_number_report_and_item_within_24_hours_is_a_duplicate(api):
    client, t = api
    rid = _report(client, t)
    first = ok(_post(client, _drop(rid), ip="198.51.100.1"), 201)
    r = _post(client, _drop(rid), ip="198.51.100.2")
    assert r.status_code == 409 and "last 24 hours" in r.json()["detail"]
    # After 24 hours it is no longer a duplicate.
    db = database.SessionLocal()
    try:
        old = datetime.now(timezone.utc) - timedelta(hours=25)
        db.query(PhysicalDonation).filter(
            PhysicalDonation.batch_reference == first["batch_reference"]
        ).update({"created_at": old})
        db.commit()
    finally:
        db.close()
    ok(_post(client, _drop(rid), ip="198.51.100.3"), 201)


def test_line_over_the_guest_cap_is_refused(api, monkeypatch):
    client, t = api
    rid = _report(client, t)
    monkeypatch.setenv("GUEST_MAX_LINE_QTY", "50")
    r = _post(client, _drop(rid, items=[{**LINE, "quantity": 51}]))
    assert r.status_code == 422 and r.json()["detail"] == "For large donations please sign in."
    ok(_post(client, _drop(rid, items=[{**LINE, "quantity": 50}])), 201)


def test_filled_honeypot_answers_201_and_saves_nothing(api):
    client, t = api
    rid = _report(client, t)
    r = _post(client, _drop(rid, website="http://spam.example"))
    assert r.status_code == 201 and r.json()["batch_reference"].startswith("DON-")
    assert _count_rows() == 0
    assert client.get(f"/donations/by-batch/{r.json()['batch_reference']}",
                      headers=t["csws"]).status_code == 404


def test_guest_entries_notify_csws_main_office_once_per_ten_minutes(api):
    client, t = api
    _activate_everyone()
    rids = [_report(client, t) for _ in range(3)]
    for n, rid in enumerate(rids):
        ok(_post(client, _drop(rid, phone=f"0917 555 02{n:02d}"), ip=f"198.51.100.{n + 1}"), 201)
    db = database.SessionLocal()
    try:
        notes = db.query(Notification).filter(
            Notification.type == "guest_donations_submitted").all()
        assert len(notes) == 1                     # one CSWS Main Office user, one notice
        assert notes[0].title == "3 new guest donations"
        assert not db.query(Notification).filter(Notification.type == "donation_submitted").count()
        # Ten minutes later a new notice starts.
        notes[0].sent_at = datetime.now(timezone.utc) - timedelta(minutes=11)
        db.commit()
    finally:
        db.close()
    ok(_post(client, _drop(_report(client, t), phone="0917 555 0299"), ip="198.51.100.9"), 201)
    db = database.SessionLocal()
    try:
        assert db.query(Notification).filter(
            Notification.type == "guest_donations_submitted").count() == 2
    finally:
        db.close()


def test_logged_in_donors_are_not_affected(api, monkeypatch):
    client, t = api
    _activate_everyone()
    rid = _report(client, t)
    monkeypatch.setenv("GUEST_MAX_LINE_QTY", "10")
    monkeypatch.setenv("GUEST_MAX_PER_IP_HOUR", "1")
    for _ in range(4):   # more than the open, duplicate and connection limits
        ok(client.post("/donations/batch", headers={**t["donor"], "X-Test-Client": "198.51.100.7"},
                       json={"report_id": rid, "handover_method": "Drop Off",
                             "items": [{**LINE, "quantity": 500}], "website": "ignored"}), 201)
    assert _count_rows() == 4
    db = database.SessionLocal()
    try:
        assert db.query(Notification).filter(Notification.type == "donation_submitted").count() == 4
    finally:
        db.close()
