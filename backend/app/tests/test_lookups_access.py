"""
F-01: GET /lookups stays public for the reference lists and the validated
reports, but the six lists of internal records reach only the staff role
whose screen uses them (api/v1/lookup_routes.py, INTERNAL_LIST_ROLES).
Everyone else gets those keys as empty lists.

Runs on the real auth stack: real /token logins and the live role names
(the `api` fixture of tests/test_role_flows.py).
"""
from datetime import datetime, timedelta, timezone

import jwt

import core.database as database
from core.config import settings
from models.report import DisasterReport
from models.user_rbac_model import User
from tests.reg_helpers import STRONG_PASSWORD, org_payload
from tests.test_role_flows import ACCOUNTS, api, ok  # noqa: F401  (fixture)

PUBLIC = ("disaster_types", "barangays", "sitios", "items", "validated_reports")
INTERNAL = ("reports", "pending_donations", "received_donations",
            "open_deliveries", "delivered_deliveries", "pending_requests")

# The internal lists each test account may receive (screen-based minimum).
ALLOWED = {
    "admin": {"reports"},
    "csws": {"reports", "pending_donations", "open_deliveries"},
    "unit": set(),
    "cmo": {"received_donations"},
    "drrmo": {"pending_requests"},
    "brgy": {"delivered_deliveries"},    # Barangay Test (id 1) only
    "brgy2": {"delivered_deliveries"},   # Barangay Two (id 2) only
    "donor": set(),
}


def _ids(lookups, key):
    return {row["id"] for row in lookups[key]}


def _user_id(email):
    db = database.SessionLocal()
    try:
        return db.query(User).filter(User.email == email).one().user_id
    finally:
        db.close()


def _report(client, t, barangay_id=1):
    return ok(client.post("/reports/", headers=t["unit"], json={
        "disaster_type_id": 1, "barangay_id": barangay_id,
        "description": "Flooding", "affected_families": 10,
        "assistance_needed": "Rice", "estimated_quantity": 100,
    }), 201)["report_id"]


def _validated(client, t, barangay_id=1):
    rid = _report(client, t, barangay_id)
    ok(client.post(f"/reports/{rid}/validate", headers=t["admin"], json={}))
    return rid


def _donate(client, t, report_id, quantity):
    return ok(client.post("/donations/", headers=t["donor"], json={
        "report_id": report_id, "item_id": 1, "packaging": "Sack",
        "handover_method": "Drop Off", "quantity": quantity,
    }))["donation_id"]


def _delivery(client, t, report_id, barangay_id):
    # Dated yesterday, so it may leave today (deliveries.py checks the date).
    when = (datetime.now(timezone.utc) - timedelta(days=1)).isoformat()
    return ok(client.post("/deliveries/", headers=t["csws"], json={
        "report_id": report_id, "destination_barangay_id": barangay_id,
        "delivery_date": when, "items": [{"item_id": 1, "quantity": 10}],
    }), 201)["delivery_id"]


def _world(client, t):
    """One record of every kind /lookups lists."""
    w = {"validated": _validated(client, t), "validated_b2": _validated(client, t, 2)}
    w["pending"] = _report(client, t)
    w["rejected"] = _report(client, t)
    ok(client.post(f"/reports/{w['rejected']}/reject", headers=t["admin"],
                   json={"rejection_reason": "Incomplete"}))
    w["cancelled"] = _report(client, t)
    ok(client.post(f"/reports/{w['cancelled']}/withdraw", headers=t["unit"], json={}))
    w["deleted"] = _report(client, t)
    ok(client.post(f"/reports/{w['deleted']}/reject", headers=t["admin"],
                   json={"rejection_reason": "Duplicate"}))
    assert client.delete(f"/reports/{w['deleted']}", headers=t["admin"]).status_code == 204

    w["pending_donation"] = _donate(client, t, w["validated"], 5)
    w["received_donation"] = _donate(client, t, w["validated"], 7)
    stock = _donate(client, t, w["validated"], 60)
    stock_b2 = _donate(client, t, w["validated_b2"], 20)
    for donation_id, qty in ((w["received_donation"], 7), (stock, 60), (stock_b2, 20)):
        ok(client.post("/donations/receive", headers=t["csws"],
                       json={"donation_id": donation_id, "actual_quantity": qty}))
    for donation_id in (stock, stock_b2):   # received_donation keeps waiting for the CMO
        ok(client.post(f"/cmo/donations/{donation_id}/confirm", headers=t["cmo"],
                       json={"status": "Confirmed"}), 201)
    w["qr_references"] = [
        ok(client.get(f"/donations/{d}/qr", headers=t["csws"]))["qr_reference"]
        for d in (w["pending_donation"], w["received_donation"], stock, stock_b2)
    ]

    w["open"] = _delivery(client, t, w["validated"], 1)            # stays Preparing
    w["delivered_b1"] = _delivery(client, t, w["validated"], 1)
    w["delivered_b2"] = _delivery(client, t, w["validated_b2"], 2)
    for did in (w["delivered_b1"], w["delivered_b2"]):
        ok(client.post(f"/deliveries/{did}/advance", headers=t["csws"]))   # In Transit
        ok(client.post(f"/deliveries/{did}/advance", headers=t["csws"]))   # Delivered
    w["request"] = ok(client.post("/logistics/requests", headers=t["csws"],
                                  json={"delivery_id": w["open"], "trucks": 1}), 201)["request_id"]
    return w


def test_guests_get_the_public_lists_and_empty_internal_lists(api):
    client, t = api
    w = _world(client, t)
    r = client.get("/lookups")
    lk = ok(r)
    assert set(lk) == set(PUBLIC) | set(INTERNAL)      # same keys as before F-01
    for key in INTERNAL:
        assert lk[key] == [], key
    # Reference data for the guest donate form and the report filters.
    assert lk["disaster_types"] == [{"id": 1, "name": "Flood"}]
    assert {b["name"] for b in lk["barangays"]} == {"Barangay Test", "Barangay Two"}
    assert [s["name"] for s in lk["sitios"]] == ["Sitio Test"]
    assert [i["name"] for i in lk["items"]] == ["Rice (kg)"]
    # Only validated reports are published: not Pending, Rejected,
    # Cancelled or deleted ones, and no donation QR reference anywhere.
    assert _ids(lk, "validated_reports") == {w["validated"], w["validated_b2"]}
    for qr in w["qr_references"]:
        assert qr not in r.text


def test_donors_and_organizations_get_exactly_the_guest_view(api):
    client, t = api
    _world(client, t)
    ok(client.post("/auth/register/organization",
                   json=org_payload(client, "relief.org@example.com")), 201)
    org = ok(client.post("/token", data={"username": "relief.org@example.com",
                                         "password": STRONG_PASSWORD}))
    org_headers = {"Authorization": f"Bearer {org['access_token']}"}
    guest = ok(client.get("/lookups"))
    assert ok(client.get("/lookups", headers=t["donor"])) == guest
    assert ok(client.get("/lookups", headers=org_headers)) == guest


def test_each_role_gets_only_its_own_internal_lists(api):
    client, t = api
    w = _world(client, t)
    expected = {
        "reports": {w["validated"], w["validated_b2"], w["pending"],
                    w["rejected"], w["cancelled"]},              # not the deleted one
        "pending_donations": {w["pending_donation"]},
        "received_donations": {w["received_donation"]},
        "open_deliveries": {w["open"]},
        "pending_requests": {w["request"]},
    }
    delivered = {"brgy": {w["delivered_b1"]}, "brgy2": {w["delivered_b2"]}}
    guest = ok(client.get("/lookups"))
    for who, allowed in ALLOWED.items():
        lk = ok(client.get("/lookups", headers=t[who]))
        for key in PUBLIC:
            assert lk[key] == guest[key], (who, key)
        for key in INTERNAL:
            if key not in allowed:
                assert lk[key] == [], (who, key)
            elif key == "delivered_deliveries":
                assert _ids(lk, key) == delivered[who], who
            else:
                assert _ids(lk, key) == expected[key], (who, key)
    # Staff see each report's status; the deleted one is gone.
    statuses = {r["id"]: r["status"]
                for r in ok(client.get("/lookups", headers=t["admin"]))["reports"]}
    assert statuses[w["pending"]] == "Pending"
    assert statuses[w["rejected"]] == "Rejected"
    assert statuses[w["cancelled"]] == "Cancelled"
    assert w["deleted"] not in statuses


def test_newer_unvalidated_reports_cannot_hide_validated_ones(api):
    """validated_reports has its own query. Before F-01 it was cut from the
    200 newest reports of any status, so 201 newer Pending reports hid it."""
    client, t = api
    rid = _validated(client, t)
    unit_id = _user_id(ACCOUNTS["unit"][0])
    db = database.SessionLocal()
    try:
        db.add_all([
            DisasterReport(user_id=unit_id, disaster_type_id=1, barangay_id=1,
                           source="Web", status="Pending", affected_families=1)
            for _ in range(201)
        ])
        db.commit()
    finally:
        db.close()
    assert rid in _ids(ok(client.get("/lookups")), "validated_reports")
    staff = ok(client.get("/lookups", headers=t["admin"]))
    assert rid in _ids(staff, "validated_reports")
    assert len(staff["reports"]) == 200       # the staff list keeps its limit


def test_bad_tokens_and_forged_roles_get_the_guest_view(api):
    """An invalid, expired or wrongly signed token is a guest; a role written
    into a token is ignored (the role comes from the database)."""
    client, t = api
    _report(client, t)                                                   # staff-only data
    assert ok(client.get("/lookups", headers=t["admin"]))["reports"]     # control

    admin_email, donor_email = ACCOUNTS["admin"][0], ACCOUNTS["donor"][0]
    admin = {"sub": admin_email, "uid": _user_id(admin_email), "role": "Administrator"}
    donor_as_admin = {"sub": donor_email, "uid": _user_id(donor_email), "role": "Administrator"}
    now = datetime.now(timezone.utc)

    def bearer(claims, key=settings.SECRET_KEY, exp=now + timedelta(minutes=30)):
        token = jwt.encode({**claims, "exp": exp}, key, algorithm=settings.ALGORITHM)
        return {"Authorization": f"Bearer {token}"}

    cases = {
        "not a token": {"Authorization": "Bearer not-a-real-token"},
        "expired": bearer(admin, exp=now - timedelta(minutes=1)),
        "wrong signature": bearer(admin, key="not-the-server-key"),
        "role claim forged": bearer(donor_as_admin),
    }
    for case, headers in cases.items():
        lk = ok(client.get("/lookups", headers=headers))
        for key in INTERNAL:
            assert lk[key] == [], (case, key)


def test_deactivated_account_is_refused_like_everywhere_else(api):
    """core/auth.get_current_user_optional: a deactivated account's old token
    gets 403, not the guest view (test_role_flows checks the same rule)."""
    client, t = api
    assert ok(client.get("/lookups", headers=t["csws"]))        # active: allowed
    db = database.SessionLocal()
    try:
        user = db.query(User).filter(User.email == ACCOUNTS["csws"][0]).one()
        user.is_active = False
        db.commit()
    finally:
        db.close()
    r = client.get("/lookups", headers=t["csws"])
    assert r.status_code == 403
    assert r.json()["detail"] == "Account is deactivated"


def test_guest_can_still_browse_and_donate(api):
    """The guest flow needs only the public lists: pick a validated report
    and an item from /lookups, then donate without logging in."""
    client, t = api
    _validated(client, t)
    lk = ok(client.get("/lookups"))
    report = lk["validated_reports"][0]
    rice = next(i for i in lk["items"] if i["item_name"] == "Rice")
    donation = ok(client.post("/donations/", json={
        "report_id": report["id"], "item_id": rice["id"], "packaging": "Box",
        "handover_method": "Drop Off", "quantity": 3,
        "guest_donor": {"full_name": "Guest Donor", "contact_number": "09171234567", "consent": True},


    }))
    assert donation["status"] == "Pending"
    assert report["id"] in {row["report_id"] for row in ok(client.get("/public/reports"))}
