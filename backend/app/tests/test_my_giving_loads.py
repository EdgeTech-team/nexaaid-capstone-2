"""G-003 (D7): My Giving must load for a donor and an organization with many
entries in every state: Pending, Partly Received, Received, Expired,
Cancelled, items the donor removed, items added later, held Door to Door
(email not verified) and closed guest-free entries. Every list view, filter
and sort of GET /donations/mine/entries and its /counts answer 200, and the
fields the app reads are never null."""
from datetime import datetime, timedelta, timezone

import core.database as database
from models.organization_model import Organization
from models.physical_donation_model import PhysicalDonation
from models.role_model import Role
from models.user_rbac_model import User
from core.auth import hash_password
from tests.test_donation_batch import LINE, _report
from tests.test_pickup_days_and_runs import _door
from tests.test_role_flows import PASSWORD, api, ok  # noqa: F401  (fixture)

SORTS = ("newest", "oldest", "most_items", "fewest_items", "due_soonest")
STATUSES = ("Pending", "Partly Received", "Received", "Confirmed", "Expired", "Cancelled", "On Hold")


def _org_account(client):
    db = database.SessionLocal()
    try:
        org = Organization(org_name="Busy Org", organization_type="Civic or Community Group",
                           organization_category="Non-government", contact_person="Ana Cruz",
                           contact_email="busy@org.ph", status="Approved")
        db.add(org)
        db.flush()
        role = db.query(Role).filter(Role.role_name == "Relief Organization").one()
        db.add(User(first_name="Ana", last_name="Cruz", contact_number="09170000009",
                    email="busy@org.ph", password_hash=hash_password(PASSWORD),
                    role_id=role.role_id, organization_id=org.organization_id))
        db.commit()
    finally:
        db.close()
    tok = ok(client.post("/token", data={"username": "busy@org.ph", "password": PASSWORD}))
    return {"Authorization": f"Bearer {tok['access_token']}"}


def _expire(ref):
    db = database.SessionLocal()
    try:
        db.query(PhysicalDonation).filter(PhysicalDonation.batch_reference == ref).update(
            {"expires_at": datetime.now(timezone.utc) - timedelta(days=1)})
        db.commit()
    finally:
        db.close()


def _make_history(client, t, who):
    rids = [_report(client, t) for _ in range(3)]
    drop = lambda rid, n=1: {"report_id": rid, "handover_method": "Drop Off",  # noqa: E731
                             "items": [dict(LINE) for _ in range(n)]}
    made = []
    for rid in rids:
        for n in (1, 3):
            made.append(ok(client.post("/donations/batch", headers=who, json=drop(rid, n)), 201))
    # Expired
    _expire(made[0]["batch_reference"])
    # Cancelled by the donor
    ok(client.post(f"/donations/entries/{made[1]['batch_reference']}/cancel", headers=who,
                   json={"reason": "Changed my mind"}))
    # An item removed with a reason, and items added later
    three = made[3]
    ok(client.post(f"/donations/entries/{three['batch_reference']}/items/"
                   f"{three['items'][0]['donation_id']}/remove", headers=who,
                   json={"reason": "Not available any more"}))
    ok(client.post(f"/donations/entries/{three['batch_reference']}/items", headers=who,
                   json={"items": [dict(LINE)]}), 201)
    # Partly received, and fully received
    part = made[5]
    ok(client.post("/donations/receive", headers=t["csws"],
                   json={"donation_id": part["items"][0]["donation_id"], "actual_quantity": 1}))
    ok(client.post("/donations/receive", headers=t["csws"],
                   json={"donation_id": made[2]["items"][0]["donation_id"], "actual_quantity": 2}))
    # A Door to Door pickup and a typed-in item
    ok(client.post("/donations/batch", headers=who, json=_door(rids[0], [3])), 201)
    ok(client.post("/donations/batch", headers=who, json={
        "report_id": rids[1], "handover_method": "Drop Off",
        "items": [{"other_item_name": "Diapers", "other_item_unit": "pcs",
                   "packaging": "Pack", "quantity": 4}]}), 201)
    # Then expire everything still waiting on one report (whole entries)
    _expire(made[4]["batch_reference"])
    return made


def _assert_loads(client, who):
    counts = ok(client.get("/donations/mine/entries/counts", headers=who))
    assert counts["all"] >= 8 and counts["summary"]["entries"] == counts["all"]
    assert counts["by_status"]["Expired"] >= 1 and counts["by_status"]["Cancelled"] >= 1
    for r in counts["reports"]:
        assert r["report_label"], r
    seen = 0
    for sort in SORTS:
        rows = ok(client.get(f"/donations/mine/entries?sort={sort}&limit=50", headers=who))
        seen = max(seen, len(rows))
        for e in rows:
            # What My giving and its cards read.
            assert e["batch_reference"] and e["status"] and e["items"] is not None, e
            assert e["report_label"] and e["handover_method"] and e["created_at"], e
            for i in e["items"]:
                assert i["item_name"] and i["packaging"] is not None and i["quantity"] is not None, i
    assert seen == counts["all"]
    for status in STATUSES:
        ok(client.get(f"/donations/mine/entries?status={status.replace(' ', '%20')}", headers=who))
    for view in ("waiting", "on_the_way"):
        ok(client.get(f"/donations/mine/entries?view={view}", headers=who))
    ok(client.get("/donations/mine/entries?q=rice&handover_method=Drop%20Off", headers=who))
    ok(client.get("/donations/mine", headers=who))


def test_my_giving_loads_for_a_donor_with_many_entries(api):
    client, t = api
    _make_history(client, t, t["donor"])
    _assert_loads(client, t["donor"])


def test_my_giving_loads_for_an_organization_with_many_entries(api):
    client, t = api
    org = _org_account(client)
    _make_history(client, t, org)
    _assert_loads(client, org)
