"""J8 / NF-014 (team agreement Nov 18, 2026, A5): unregistered SMS sender.

Done when (task brief J8):
  - an unknown number without a reason = 422
  - with a reason = 201 + warning (saved, shown as a warning until validated)
  - a registered number is unchanged
Also: a blank or too long reason = 422 and nothing is saved; a deactivated
member's number, or a number of another role, is unknown; the reason is in
the ENCODE SMS REPORT audit row; the J7 lock still holds (the reason cannot
be added or changed with a PATCH); the role checks.
Real auth stack: the `api` fixture of tests/test_role_flows.py.
"""
import core.shared.database as database
from core.shared.audit_log_model import AuditLog
from core.m2_disaster_reporting.report_model import DisasterReport, SmsReportMetadata
from core.m1_user_management.user_rbac_model import User
from tests.m1_user_management.test_role_flows import api, ok  # noqa: F401  (fixture)

REGISTERED = "+63 917 000 0000"        # every test account's number (the Disaster Unit member's)
UNKNOWN = "09998887777"
SMS = {"raw_message": "NEXAAID REPORT\nTYPE: Flood\nFAMILIES: 5",
       "disaster_type_id": 1, "barangay_id": 1, "affected_families": 5}
REASON = "Sent from the barangay captain's phone; the unit's phone was down"


# ------------------------------------------------------------------ helpers
def _ready():
    from tests.m5_inventory.test_pickup_days_and_runs import _activate_everyone
    _activate_everyone()          # SQLite stores is_active as text


def _encode(client, t, number, **extra):
    return client.post("/reports/sms", headers=t["admin"],
                       json={**SMS, "contact_number": number, **extra})


def _set_user(first_name, **values):
    db = database.SessionLocal()
    try:
        db.query(User).filter(User.first_name == first_name).update(values)
        db.commit()
    finally:
        db.close()


def _counts():
    db = database.SessionLocal()
    try:
        return (db.query(DisasterReport).count(), db.query(SmsReportMetadata).count(),
                db.query(AuditLog).filter(AuditLog.action == "ENCODE SMS REPORT").count())
    finally:
        db.close()


def _user_id(first_name):
    db = database.SessionLocal()
    try:
        return db.query(User.user_id).filter(User.first_name == first_name).scalar()
    finally:
        db.close()


def _encode_log(client, t, rid):
    rows = ok(client.get("/admin/audit-logs?entity_type=disaster_reports", headers=t["admin"]))
    [row] = [r for r in rows if r["entity_id"] == rid and r["action"] == "ENCODE SMS REPORT"]
    return row["new_value"]


# ------------------------------ Done when: unknown number, no reason = 422
def test_an_unknown_number_without_a_reason_is_422(api):
    client, t = api
    _ready()
    before = _counts()
    for extra in ({}, {"unregistered_sender_reason": None},
                  {"unregistered_sender_reason": ""}, {"unregistered_sender_reason": "   "}):
        r = _encode(client, t, UNKNOWN, **extra)
        assert r.status_code == 422, extra
        assert "matches no active CSWS Disaster Unit member" in r.json()["detail"]
    r = _encode(client, t, UNKNOWN, unregistered_sender_reason="x" * 501)
    assert r.status_code == 422                                     # too long
    assert _counts() == before                                      # nothing saved, nothing logged


def test_a_deactivated_member_or_another_roles_number_is_unknown(api):
    client, t = api
    _ready()
    # Another role's number (CSWS Main Office) is not a Disaster Unit member's.
    _set_user("csws", contact_number="09175550000")
    assert _encode(client, t, "09175550000").status_code == 422
    # The Disaster Unit member, deactivated: their number is unknown now.
    _set_user("unit", is_active=False)
    assert _encode(client, t, REGISTERED).status_code == 422


# ------------------------------ Done when: with a reason = 201 + warning
def test_with_a_reason_it_is_201_with_a_warning_until_validated(api):
    client, t = api
    _ready()
    made = ok(_encode(client, t, UNKNOWN, unregistered_sender_reason=f"  {REASON}  "), 201)
    rid = made["report"]["report_id"]
    assert REASON in made["warning"] and "Unregistered sender" in made["warning"]
    assert made["sms_metadata"]["unregistered_sender_reason"] == REASON      # saved, trimmed
    assert made["sms_metadata"]["warning"] == made["warning"]
    assert made["report"]["user_id"] == _user_id("admin")                   # filed under the encoder
    assert _encode_log(client, t, rid)["unregistered_sender_reason"] == REASON

    # Shown on validation while Pending, and still after a rejection...
    meta = ok(client.get(f"/reports/{rid}/sms-metadata", headers=t["admin"]))
    assert REASON in meta["warning"]
    ok(client.post(f"/reports/{rid}/reject", headers=t["admin"],
                   json={"rejection_reason": "Call the unit to confirm"}))
    assert REASON in ok(client.get(f"/reports/{rid}/sms-metadata", headers=t["admin"]))["warning"]

    # ...until validated: then no warning, the reason stays on record.
    ok(client.post(f"/reports/{rid}/validate", headers=t["admin"], json={}))
    meta = ok(client.get(f"/reports/{rid}/sms-metadata", headers=t["admin"]))
    assert meta["warning"] is None and meta["unregistered_sender_reason"] == REASON


# ------------------------------- Done when: registered number unchanged
def test_a_registered_number_is_unchanged(api):
    client, t = api
    _ready()
    made = ok(_encode(client, t, REGISTERED), 201)
    assert made["warning"] is None
    assert made["sms_metadata"]["unregistered_sender_reason"] is None
    assert made["sms_metadata"]["warning"] is None
    assert made["report"]["user_id"] == _user_id("unit")                    # filed under the sender
    assert _encode_log(client, t, made["report"]["report_id"])["unregistered_sender_reason"] is None
    # A reason sent with a registered number is ignored, not saved.
    again = ok(_encode(client, t, "09170000000", unregistered_sender_reason=REASON), 201)
    assert again["warning"] is None and again["sms_metadata"]["unregistered_sender_reason"] is None


# ------------------------------------------------------- J7 lock still holds
def test_the_reason_cannot_be_added_or_changed_after_encoding(api):
    client, t = api
    _ready()
    rid = ok(_encode(client, t, UNKNOWN, unregistered_sender_reason=REASON), 201)["report"]["report_id"]
    r = client.patch(f"/reports/{rid}", headers=t["admin"],
                     json={"unregistered_sender_reason": "Changed", "description": "x"})
    assert r.status_code == 409
    assert ok(client.get(f"/reports/{rid}/sms-metadata",
                         headers=t["admin"]))["unregistered_sender_reason"] == REASON


# ------------------------------------------------------------- who may
def test_role_checks(api):
    client, t = api
    _ready()
    rid = ok(_encode(client, t, UNKNOWN, unregistered_sender_reason=REASON), 201)["report"]["report_id"]
    body = {**SMS, "contact_number": UNKNOWN, "unregistered_sender_reason": REASON}
    for who in ("unit", "csws", "brgy", "donor", "cmo", "drrmo"):
        assert client.post("/reports/sms", headers=t[who], json=body).status_code == 403, who
    for who in ("csws", "brgy", "donor", "cmo", "drrmo"):
        assert client.get(f"/reports/{rid}/sms-metadata", headers=t[who]).status_code == 403, who
    assert REASON in ok(client.get(f"/reports/{rid}/sms-metadata", headers=t["unit"]))["warning"]
