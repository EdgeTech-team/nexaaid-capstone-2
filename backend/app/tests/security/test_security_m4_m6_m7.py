"""
G-002 / G-004 (T4): security and error checks for Dave's modules
(M4 Donation Management, M6 City Confirmation, M7 Logistics Support).

- S-1 Every role-checked endpoint answers 403 to a valid token of a role it
  does not allow. The routes come from the routers themselves, so a new
  endpoint is covered without editing this test.
- S-2 A donor can neither read nor change another donor's donations.
- S-5 No list response carries a valid ID / government ID field.
- S-6 DRRMO's picked-up / delivered steps are in the activity log.
- E-3 Errors are JSON with a readable "detail", never a stack trace.
"""
import inspect
import re
from datetime import datetime, timezone

import pytest

from core.config import database
from core.security.auth import has_role, hash_password
from models.security.audit_log_model import AuditLog
from models.deliveries.delivery import Delivery
from models.deliveries.logistics_request_model import LogisticsRequest
from models.accounts.user_rbac_model import User
from tests.donations.test_donation_batch import LINE, _report
from tests.general.test_role_flows import ACCOUNTS, PASSWORD, api, ok  # noqa: F401  (fixture)

# Dave's routers. receiving_routes also holds M5 (CSWS receiving and
# inventory, Mariquit): only its Module 4.4 / 4.5 records routes are his.
MODULES = {
    "donations.donation_routes": None,
    "donations.donation_lifecycle_routes": None,
    "pickup.pickup_plan_routes": None,
    "receiving.receiving_routes": re.compile(r"^/donations/records"),
    "donations.cmo_router": None,
    "deliveries.logistics_router": None,
    "deliveries.drrmo_router": None,
}


def _allowed_roles(route):
    """The roles of the route's require_role(...) dependency, or None."""
    def walk(dep):
        for d in dep.dependencies:
            fn = d.call
            if inspect.isfunction(fn) and fn.__name__ == "role_checker":
                return inspect.getclosurevars(fn).nonlocals["allowed_roles"]
            found = walk(d)
            if found is not None:
                return found
        return None
    return walk(route.dependant)


def _role_checked_routes():
    import importlib

    from fastapi.routing import APIRoute
    out = []
    for mod, only in MODULES.items():
        router = importlib.import_module(f"api.v1.{mod}").router
        for r in router.routes:
            if not isinstance(r, APIRoute) or (only and not only.match(r.path)):
                continue
            roles = _allowed_roles(r)
            if roles:
                for method in sorted(r.methods):
                    out.append((method, r.path, tuple(roles)))
    return out


ROUTES = _role_checked_routes()


def test_the_audit_covers_dave_s_endpoints():
    paths = {p for _, p, _ in ROUTES}
    for must in ("/donations/records", "/cmo/entries/pending", "/cmo/report-summaries",
                 "/drrmo/requests", "/logistics/requests", "/donations/pickup-plan"):
        assert must in paths, must
    assert not any(p.startswith(("/donations/inventory", "/donations/receive")) for p in paths)


def test_wrong_roles_get_403_on_every_endpoint(api):
    client, t = api
    db = database.SessionLocal()
    users = {key: db.query(User).filter(User.email == email).one() for key, (email, _) in ACCOUNTS.items()}
    checked = 0
    for method, path, roles in ROUTES:
        url = re.sub(r"\{[^}]+\}", "1", path)
        for key, user in users.items():
            if has_role(user, *roles):
                continue
            r = client.request(method, url, headers=t[key],
                               json={} if method in ("POST", "PUT", "PATCH") else None)
            assert r.status_code == 403, f"{key} {method} {path} -> {r.status_code}: {r.text[:120]}"
            assert r.json()["detail"]
            checked += 1
    db.close()
    assert checked > 100  # every endpoint, several roles each


def _second_donor():
    db = database.SessionLocal()
    db.add(User(first_name="Other", last_name="Donor", contact_number="09170000001",
                email="other.donor@example.com", password_hash=hash_password(PASSWORD), role_id=2))
    db.commit()
    db.close()


def test_a_donor_cannot_read_or_change_another_donors_donation(api):
    client, t = api
    _second_donor()
    other = {"Authorization": "Bearer " + ok(client.post("/token", data={
        "username": "other.donor@example.com", "password": PASSWORD}))["access_token"]}
    rid = _report(client, t)
    mine = ok(client.post("/donations/batch", headers=t["donor"], json={
        "report_id": rid, "handover_method": "Drop Off", "items": [LINE]}), 201)
    ref = mine["batch_reference"]
    first_id = ok(client.get("/donations/mine", headers=t["donor"]))["entries"][0]["items"][0]["donation_id"]

    theirs = ok(client.get("/donations/mine", headers=other))
    assert theirs["entries"] == []
    assert ref not in str(ok(client.get("/donations/entries", headers=other)))
    assert client.get(f"/donations/{first_id}/qr", headers=other).status_code == 404
    for method, url, body in (
        ("POST", f"/donations/entries/{ref}/cancel", {"reason": "I changed my mind"}),
        ("PUT", f"/donations/entries/{ref}", {"report_id": rid, "handover_method": "Drop Off",
                                              "items": [LINE]}),
        ("DELETE", f"/donations/entries/{ref}", None),
        ("POST", f"/donations/entries/{ref}/items", {"items": [LINE]}),
    ):
        r = client.request(method, url, headers=other, json=body)
        assert r.status_code in (403, 404), (method, url, r.status_code, r.text)
    # The owner's donation is untouched
    assert ok(client.get("/donations/mine", headers=t["donor"]))["entries"][0]["status"] == "Pending"


def test_no_list_response_carries_a_valid_id(api):
    client, t = api
    rid = _report(client, t)
    ok(client.post("/donations/batch", headers=t["donor"], json={
        "report_id": rid, "handover_method": "Drop Off", "items": [LINE]}), 201)
    lists = [
        ("admin", "/donations/records"), ("admin", "/donations/records/per-report"),
        ("csws", "/donations/entries"), ("donor", "/donations/mine"), ("donor", "/donations/entries"),
        ("cmo", "/cmo/entries/pending"), ("cmo", "/cmo/entries/acknowledged"),
        ("cmo", "/cmo/dashboard"), ("cmo", "/cmo/report-summaries"),
        ("drrmo", "/drrmo/requests"), ("csws", "/logistics/requests"), ("csws", "/donations/pickups"),
        ("brgy", "/donations/records"),
    ]
    for who, path in lists:
        text = client.get(path, headers=t[who]).text.lower()
        for word in ("id_document", "id_type", "valid_id", "government_id", "id_front", "id_back"):
            assert word not in text, (path, word)


def test_drrmo_delivery_steps_are_in_the_activity_log(api):
    client, t = api
    rid = _report(client, t)
    db = database.SessionLocal()
    csws = db.query(User).filter(User.email == "csws.test@example.com").one()
    d = Delivery(report_id=rid, destination_barangay_id=1, handled_by_user_id=csws.user_id,
                 status="Preparing", delivery_date=datetime.now(timezone.utc))
    db.add(d)
    db.flush()
    req = LogisticsRequest(delivery_id=d.delivery_id, requested_by_user_id=csws.user_id,
                           status="Pending", request_type="Delivery")
    db.add(req)
    db.commit()
    request_id = req.request_id
    db.close()

    # UC-DR1 step 5: a delivery request is accepted with DRRMO's pickup time.
    when = datetime.now(timezone.utc).isoformat()
    ok(client.patch(f"/drrmo/requests/{request_id}/accept", headers=t["drrmo"],
                    json={"scheduled_date": when}))
    ok(client.post(f"/drrmo/requests/{request_id}/picked-up", headers=t["drrmo"]))
    ok(client.post(f"/drrmo/requests/{request_id}/delivered", headers=t["drrmo"]))
    db = database.SessionLocal()
    actions = [a.action for a in db.query(AuditLog).filter(
        AuditLog.entity_type == "logistics_requests", AuditLog.entity_id == request_id)
        .order_by(AuditLog.log_id)]
    db.close()
    # Arriving also completes the request (Table 36), which logs its own line.
    assert actions[0] == "ACCEPT LOGISTICS REQUEST"
    assert [a for a in actions if a.startswith("DRRMO ")] == [
        "DRRMO PICKED UP DELIVERY", "DRRMO DELIVERED"]


@pytest.mark.parametrize("method,url,body,code", [
    ("GET", "/donations/records?limit=0", None, 422),
    ("GET", "/donations/records?sort=bogus", None, 422),
    ("POST", "/cmo/entries/DON-NOPE/decide", {"status": "Acknowledged"}, 404),
    ("POST", "/cmo/entries/DON-NOPE/decide", {"status": "Maybe"}, 422),
    ("PATCH", "/drrmo/requests/999999/accept", {}, 404),
])
def test_errors_are_json_with_a_readable_detail(api, method, url, body, code):
    client, t = api
    who = "cmo" if url.startswith("/cmo") else "drrmo" if url.startswith("/drrmo") else "admin"
    r = client.request(method, url, headers=t[who], json=body)
    assert r.status_code == code, r.text
    detail = r.json()["detail"]
    assert detail and "Traceback" not in str(detail)


# S-1: who may call each endpoint, from the List of Modules role columns
# (Appendix H) and the team decisions in the audit. The code must match this
# table exactly, and a new role-checked endpoint fails until it is added here.
ADMIN, CSWS, UNIT, CMO_R = "Administrator", "CSWS Main Office", "CSWS Disaster Unit", "CMO Representative"
DONOR, ORG, BRGY, DRRMO_R = ("Individual Donor", "Relief Organization",
                             "Barangay Receiving Representative", "DRRMO Logistics Support")
RECORDS = (ADMIN, CSWS, CMO_R, BRGY)                    # 4.4 / 4.5 staff records
EXPECTED = {
    ("GET", "/donations/by-batch/{reference}"): (CSWS, ADMIN),
    ("GET", "/donations/pickups"): (CSWS, ADMIN),
    ("GET", "/donations/entries"): (ADMIN, CSWS, CMO_R, DONOR, ORG),
    ("POST", "/donations/entries/{reference}/reinstate"): (CSWS, ADMIN),
    ("GET", "/donations/pickup-plan"): (CSWS, ADMIN),
    ("POST", "/donations/pickup-plan/not-home"): (CSWS, ADMIN),
    # NF-007 (D5): the call that confirms a pickup stop.
    ("POST", "/donations/entries/{reference}/contact-check"): (CSWS, DRRMO_R, ADMIN),
    ("GET", "/donations/records"): RECORDS,
    ("GET", "/donations/records/counts"): RECORDS,
    ("GET", "/donations/records/per-report"): RECORDS,
    ("POST", "/cmo/donations/{donation_id}/confirm"): (CMO_R,),   # 6.2
    ("GET", "/cmo/entries/pending"): (CMO_R,),                    # 6.1
    ("GET", "/cmo/entries/acknowledged"): (CMO_R,),
    ("GET", "/cmo/entries/by-donation/{donation_id}"): (CMO_R,),
    ("POST", "/cmo/entries/{reference}/decide"): (CMO_R,),
    ("GET", "/cmo/donations/pending"): (CMO_R,),
    ("GET", "/cmo/donations/confirmed"): (CMO_R,),
    ("GET", "/cmo/dashboard"): (CMO_R, ADMIN),                    # 6.3
    ("GET", "/cmo/report-summaries"): (CMO_R, ADMIN),             # 6.3
    ("POST", "/logistics/requests"): (CSWS,),                     # 7.1
    ("POST", "/logistics/pickup-requests"): (CSWS,),
    # 7.5 + the Disaster Unit's own pickup runs (team decision, Oct)
    ("GET", "/logistics/requests"): (CSWS, ADMIN, UNIT),
    ("GET", "/drrmo/requests"): (DRRMO_R,),                       # 7.2
    ("GET", "/drrmo/requests/counts"): (DRRMO_R,),
    ("PATCH", "/drrmo/requests/{request_id}/accept"): (DRRMO_R,),  # 7.3
    ("PATCH", "/drrmo/requests/{request_id}/decline"): (DRRMO_R,),
    # Table 36 / 37: the DRRMO user who accepted it, or the Administrator.
    ("POST", "/drrmo/requests/{request_id}/picked-up"): (DRRMO_R, ADMIN),
    ("POST", "/drrmo/requests/{request_id}/delivered"): (DRRMO_R, ADMIN),
    ("PATCH", "/drrmo/requests/{request_id}/complete"): (DRRMO_R,),  # 7.5
    ("GET", "/drrmo/dashboard"): (DRRMO_R,),
}


def test_endpoint_roles_match_the_list_of_modules():
    from core.security.auth import expand_roles
    actual = {(m, p): roles for m, p, roles in ROUTES}
    assert set(actual) == set(EXPECTED), (
        f"not in EXPECTED: {sorted(set(actual) - set(EXPECTED))}; "
        f"gone: {sorted(set(EXPECTED) - set(actual))}")
    for key, roles in actual.items():
        assert expand_roles(*roles) == expand_roles(*EXPECTED[key]), (key, roles)
