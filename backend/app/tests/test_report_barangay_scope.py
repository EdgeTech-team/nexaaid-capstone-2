"""
F-05: a Barangay Receiving Representative opens a report that is not
validated yet (Pending, Rejected, Cancelled) only in its own assigned
barangay, on all three single-report endpoints. Validated reports stay open
as before. Real auth stack: the `api` fixture of tests/test_role_flows.py.
Barangay Test is id 1 (rep "brgy"), Barangay Two is id 2 (rep "brgy2").
"""
import core.database as database
from core.auth import hash_password
from models.user_rbac_model import User
from tests.test_role_flows import PASSWORD, api, ok  # noqa: F401  (fixture)
from tests.test_pickup_days_and_runs import _activate_everyone

# Each endpoint keeps its own "no" answer.
REFUSED = {"/reports/{}": 403, "/reports/{}/needs": 404, "/reports/{}/donation-info": 404}


def _report(client, t, barangay_id):
    return ok(client.post("/reports/", headers=t["unit"], json={
        "disaster_type_id": 1, "barangay_id": barangay_id, "estimated_quantity": 10}), 201)["report_id"]


def _sees(client, headers, rid):
    """True when all three endpoints answer 200, False when all three refuse
    with their usual code. A mix fails the test."""
    codes = {p: client.get(p.format(rid), headers=headers).status_code for p in REFUSED}
    if all(c == 200 for c in codes.values()):
        return True
    assert codes == REFUSED, codes
    return False


def _unvalidated(client, t, barangay_id):
    """A Pending, a Rejected and a Cancelled report in that barangay."""
    pending = _report(client, t, barangay_id)
    rejected = _report(client, t, barangay_id)
    ok(client.post(f"/reports/{rejected}/reject", headers=t["admin"],
                   json={"rejection_reason": "Incomplete"}))
    cancelled = _report(client, t, barangay_id)
    ok(client.post(f"/reports/{cancelled}/withdraw", headers=t["unit"], json={}))
    return [pending, rejected, cancelled]


def test_rep_sees_unvalidated_reports_of_its_own_barangay_only(api):
    client, t = api
    own, other = _unvalidated(client, t, 1), _unvalidated(client, t, 2)
    for rid in own:
        assert _sees(client, t["brgy"], rid)
        assert not _sees(client, t["brgy2"], rid)
    for rid in other:
        assert not _sees(client, t["brgy"], rid)
        assert _sees(client, t["brgy2"], rid)


def test_validated_reports_stay_open(api):
    client, t = api
    rid = _report(client, t, 2)
    ok(client.post(f"/reports/{rid}/validate", headers=t["admin"], json={}))
    for who in ("brgy", "brgy2", "donor", "cmo", "drrmo", "csws", "unit", "admin"):
        assert _sees(client, t[who], rid), who
    # Guests: the report itself needs a login, as before; needs and payment info are public.
    assert client.get(f"/reports/{rid}").status_code == 401
    ok(client.get(f"/reports/{rid}/needs"))
    ok(client.get(f"/reports/{rid}/donation-info"))


def test_staff_keep_their_access_and_others_stay_out(api):
    client, t = api
    for rid in _unvalidated(client, t, 2):
        for who in ("admin", "csws", "unit"):          # unit is also the submitter
            assert _sees(client, t[who], rid), who
        for who in ("donor", "cmo", "drrmo"):
            assert not _sees(client, t[who], rid), who
        assert client.get(f"/reports/{rid}").status_code == 401             # guest
        assert client.get(f"/reports/{rid}/needs").status_code == 404
        assert client.get(f"/reports/{rid}/donation-info").status_code == 404


def test_rep_without_a_barangay_sees_no_unvalidated_report(api):
    client, t = api
    db = database.SessionLocal()
    try:
        db.add(User(first_name="nobrgy", last_name="Test", contact_number="09170000000",
                    email="nobrgy.test@example.com", password_hash=hash_password(PASSWORD),
                    role_id=7, assigned_barangay_id=None))   # Barangay Receiving Representative
        db.commit()
    finally:
        db.close()
    login = ok(client.post("/token", data={"username": "nobrgy.test@example.com", "password": PASSWORD}))
    rep = {"Authorization": f"Bearer {login['access_token']}"}
    pending = _report(client, t, 1)
    assert not _sees(client, rep, pending)
    ok(client.post(f"/reports/{pending}/validate", headers=t["admin"], json={}))
    assert _sees(client, rep, pending)                       # validated: open, no error


def test_lists_notifications_and_f04_are_unchanged(api):
    client, t = api
    _activate_everyone()          # SQLite: make is_active a real boolean so notices are sent

    client, t = api
    own, other = _report(client, t, 1), _report(client, t, 2)
    # Lists were already scoped (unchanged).
    assert {r["report_id"] for r in ok(client.get("/reports/", headers=t["brgy"]))} == {own}
    assert {r["report_id"] for r in ok(client.get("/reports/monitoring", headers=t["brgy"]))} == {own}
    # The "validated" notice reaches its own barangay's rep, and opening it works.
    ok(client.post(f"/reports/{own}/validate", headers=t["admin"], json={}))
    notes = ok(client.get("/notifications/", headers=t["brgy"]))["items"]
    rid = next(n["entity_id"] for n in notes
               if n["entity_type"] == "report" and n["entity_id"] == own)
    ok(client.get(f"/reports/{rid}", headers=t["brgy"]))
    # F-04 still holds: a rep cannot set a report's payment details; the submitter
    # can on a Pending report.
    info = {"provider": "GCash", "account_name": "Relief Desk", "account_number": "09180000000"}
    assert client.put(f"/reports/{other}/donation-info", headers=t["brgy"], json=info).status_code == 403
    ok(client.put(f"/reports/{other}/donation-info", headers=t["unit"], json=info))
