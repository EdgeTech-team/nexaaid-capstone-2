"""NF-006 (D4): verify the account email once, for Door to Door pickups,
and NF-011 (D3): which pledges are verified.

Agreement A4: registration still signs in at once. A Door to Door donation
from an unverified account is saved but stays off the CSWS pickup list,
planner and map until the email is verified; then its handover deadline
counts from that moment. Unverified Door to Door entries expire after 48
hours ("Email not verified"). Drop Off never needs it."""
import re
from datetime import datetime, timedelta, timezone

import core.database as database
from models.email_verification_model import EmailVerificationCode
from models.physical_donation_model import PhysicalDonation
from models.user_rbac_model import User
from services.donation_expiry import utc
from services.pledge_trust import pledge_is_verified
from tests.test_donation_batch import LINE, _report
from tests.test_pickup_days_and_runs import _door, _next
from tests.test_role_flows import ACCOUNTS, api, ok  # noqa: F401  (fixture)

DONOR = ACCOUNTS["donor"][0]


def _capture(monkeypatch):
    """auth_router imported send_email directly, so patch it there."""
    sent = []
    monkeypatch.setattr(
        "api.v1.auth_router.send_email",
        lambda to, subject, body: sent.append({"to": to, "subject": subject, "body": body}) or True,
    )
    return sent


def _code(mail):
    return re.search(r"code is (\d{6})", mail["body"]).group(1)


def _set(email, **values):
    db = database.SessionLocal()
    try:
        db.query(User).filter(User.email == email).update(values)
        db.commit()
    finally:
        db.close()


def _unverify(email=DONOR):
    _set(email, email_verified_at=None)


def _rows(ref):
    db = database.SessionLocal()
    try:
        return db.query(PhysicalDonation).filter(PhysicalDonation.batch_reference == ref).all()
    finally:
        db.close()


def _board_refs(client, t):
    return {b["batch_reference"] for b in ok(client.get("/donations/pickups", headers=t["csws"]))}


def _plan_refs(client, t):
    plan = ok(client.get("/donations/pickup-plan", headers=t["csws"]))
    return ({d["batch_reference"] for s in plan["stops"] for d in s["donations"]}
            | {d["batch_reference"] for d in plan["follow_up"]})


def test_unverified_door_to_door_is_kept_off_the_pickup_map(api):
    client, t = api
    _unverify()
    rid = _report(client, t)
    b = ok(client.post("/donations/batch", headers=t["donor"], json=_door(rid, [3])), 201)
    ref = b["batch_reference"]
    assert b["awaiting_email"] is True
    assert b["email_hold_message"] == "Check your email. Enter the code to send this pickup to CSWS."
    assert ref not in _board_refs(client, t)
    assert ref not in _plan_refs(client, t)
    r = client.post("/logistics/pickup-requests", headers=t["csws"], json={
        "pickup_date": _next(3).isoformat(), "batch_references": [ref], "trucks": 1})
    assert r.status_code == 409 and "verify their email" in r.text
    # It is saved, and expires 48 hours after it was made.
    row = _rows(ref)[0]
    left = utc(row.expires_at) - datetime.now(timezone.utc)
    assert timedelta(hours=47) < left <= timedelta(hours=48)
    # The login payload tells the app to show the banner.
    assert ok(client.get("/auth/me", headers=t["donor"]))["email_verified"] is False


def test_drop_off_never_needs_verification(api):
    client, t = api
    _unverify()
    rid = _report(client, t)
    b = ok(client.post("/donations/batch", headers=t["donor"], json={
        "report_id": rid, "handover_method": "Drop Off", "items": [LINE]}), 201)
    assert b["awaiting_email"] is False and "email_hold_message" not in b
    row = _rows(b["batch_reference"])[0]
    assert utc(row.expires_at) - datetime.now(timezone.utc) > timedelta(days=13)


def test_confirming_the_code_puts_the_pickup_on_the_map(api, monkeypatch):
    client, t = api
    sent = _capture(monkeypatch)
    _unverify()
    rid = _report(client, t)
    ref = ok(client.post("/donations/batch", headers=t["donor"], json=_door(rid, [3])),
             201)["batch_reference"]
    held_deadline = utc(_rows(ref)[0].expires_at)

    r = ok(client.post("/auth/verify-email/send", headers=t["donor"]))
    assert r["email_verified"] is False and sent[-1]["to"] == DONOR
    done = ok(client.post("/auth/verify-email/confirm", headers=t["donor"],
                          json={"code": _code(sent[-1])}))
    assert done["email_verified"] is True and done["released"] == [ref]

    assert ref in _board_refs(client, t)
    assert ref in _plan_refs(client, t)
    # The handover deadline counts from the verification, not the 48-hour hold.
    assert utc(_rows(ref)[0].expires_at) - held_deadline > timedelta(days=10)
    assert ok(client.get("/auth/me", headers=t["donor"]))["email_verified"] is True
    # Once per account: the next Door to Door donation goes straight through.
    again = ok(client.post("/donations/batch", headers=t["donor"], json=_door(rid, [4])), 201)
    assert again["awaiting_email"] is False and again["batch_reference"] in _board_refs(client, t)
    assert ok(client.post("/auth/verify-email/send", headers=t["donor"]))["email_verified"] is True
    assert len(sent) == 1                                   # no new code is sent


def test_five_wrong_codes_answer_429(api, monkeypatch):
    client, t = api
    sent = _capture(monkeypatch)
    _unverify()
    ok(client.post("/auth/verify-email/send", headers=t["donor"]))
    good = _code(sent[-1])
    wrong = f"{(int(good) + 1) % 1_000_000:06d}"
    for _ in range(4):
        r = client.post("/auth/verify-email/confirm", headers=t["donor"], json={"code": wrong})
        assert r.status_code == 400 and "Wrong code" in r.text
    r = client.post("/auth/verify-email/confirm", headers=t["donor"], json={"code": wrong})
    assert r.status_code == 429
    # The right code no longer works either; a new one does.
    r = client.post("/auth/verify-email/confirm", headers=t["donor"], json={"code": good})
    assert r.status_code == 429
    ok(client.post("/auth/verify-email/send", headers=t["donor"]))
    ok(client.post("/auth/verify-email/confirm", headers=t["donor"], json={"code": _code(sent[-1])}))


def test_expired_code_answers_400(api, monkeypatch):
    client, t = api
    sent = _capture(monkeypatch)
    _unverify()
    ok(client.post("/auth/verify-email/send", headers=t["donor"]))
    db = database.SessionLocal()
    try:
        db.query(EmailVerificationCode).update(
            {"expires_at": datetime.now(timezone.utc) - timedelta(minutes=1)})
        db.commit()
    finally:
        db.close()
    r = client.post("/auth/verify-email/confirm", headers=t["donor"], json={"code": _code(sent[-1])})
    assert r.status_code == 400 and "expired" in r.text


def test_at_most_five_codes_an_hour(api, monkeypatch):
    client, t = api
    _capture(monkeypatch)
    _unverify()
    for _ in range(5):
        ok(client.post("/auth/verify-email/send", headers=t["donor"]))
    assert client.post("/auth/verify-email/send", headers=t["donor"]).status_code == 429


def test_unverified_door_to_door_expires_after_48_hours(api):
    client, t = api
    _unverify()
    rid = _report(client, t)
    ref = ok(client.post("/donations/batch", headers=t["donor"], json=_door(rid, [3])),
             201)["batch_reference"]
    db = database.SessionLocal()
    try:
        db.query(PhysicalDonation).filter(PhysicalDonation.batch_reference == ref).update(
            {"expires_at": datetime.now(timezone.utc) - timedelta(minutes=1)})
        db.commit()
    finally:
        db.close()
    ok(client.get("/donations/mine", headers=t["donor"]))     # runs the expiry check
    row = _rows(ref)[0]
    assert row.status == "Expired" and row.close_reason == "Email not verified"


def test_staff_accounts_count_as_verified_in_the_login_payload(api):
    client, t = api
    assert ok(client.get("/auth/me", headers=t["csws"]))["email_verified"] is True


# --------------------------------------------------------------------------
# NF-011 (D3): pledge_verified
# --------------------------------------------------------------------------
def test_guest_pledge_is_not_verified_until_csws_receives_it(api):
    client, t = api
    rid = _report(client, t)
    g = ok(client.post("/donations/batch", json={
        "report_id": rid, "handover_method": "Drop Off", "items": [LINE],
        "guest_donor": {"full_name": "Gina Guest", "contact_number": "09171112222", "consent": True},
    }), 201)
    assert g["pledge_verified"] is False and g["pledge_flag"] == "Guest – not yet received"
    queue = ok(client.get("/donations/receive-queue", headers=t["csws"]))
    entry = next(e for e in queue if e["batch_reference"] == g["batch_reference"])
    assert entry["pledge_verified"] is False and entry["pledge_flag"] == "Guest – not yet received"

    ok(client.post("/donations/receive", headers=t["csws"],
                   json={"donation_id": g["items"][0]["donation_id"], "actual_quantity": 2}))
    after = ok(client.get(f"/donations/by-batch/{g['batch_reference']}", headers=t["csws"]))
    assert after["pledge_verified"] is True and after["pledge_flag"] is None
    assert after["items"][0]["pledge_verified"] is True


def test_verified_donor_pledge_is_verified_and_unverified_is_flagged(api):
    client, t = api
    rid = _report(client, t)
    body = {"report_id": rid, "handover_method": "Drop Off", "items": [LINE]}
    mine = ok(client.post("/donations/batch", headers=t["donor"], json=body), 201)
    assert mine["pledge_verified"] is True and mine["pledge_flag"] is None
    _unverify()
    other = ok(client.post("/donations/batch", headers=t["donor"],
                           json={**body, "report_id": _report(client, t)}), 201)
    assert other["pledge_verified"] is False and other["pledge_flag"] == "Email not verified"


def test_pledge_is_verified_helper():
    class Row:
        def __init__(self, status, user_id):
            self.status, self.user_id = status, user_id

    class Account:
        def __init__(self, at):
            self.email_verified_at = at

    now = datetime.now(timezone.utc)
    assert pledge_is_verified(Row("Pending", None), None) is False          # guest
    assert pledge_is_verified(Row("Received", None), None) is True          # guest, received
    assert pledge_is_verified(Row("Pending", 5), Account(now)) is True      # verified donor
    assert pledge_is_verified(Row("Pending", 5), Account(None)) is False    # email not verified
    assert pledge_is_verified(Row("Confirmed", 5), Account(None)) is True
