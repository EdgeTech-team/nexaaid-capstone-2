"""Defense fixes (Nov 23, 2026)."""
from datetime import datetime, timezone

import core.shared.database as database
from core.m1_user_management.user_rbac_model import User
from tests.m1_user_management.test_role_flows import api, ok  # noqa: F401  (fixture)


def test_admin_user_count_leaves_out_deleted_accounts(api):
    client, t = api
    before = ok(client.get("/dashboard/admin", headers=t["admin"]))
    db = database.SessionLocal()
    try:
        u = db.query(User).filter(User.email == "donor.test@example.com").one()
        u.is_active = False
        u.deleted_at = datetime.now(timezone.utc)
        db.commit()
    finally:
        db.close()
    after = ok(client.get("/dashboard/admin", headers=t["admin"]))
    assert after["total_users"] == before["total_users"] - 1
    assert after["active_users"] <= before["active_users"]


def test_report_counts_follow_barangay_and_disaster_type(api):
    client, t = api
    rid = ok(client.post("/reports/", headers=t["unit"], json={
        "disaster_type_id": 1, "barangay_id": 1, "estimated_quantity": 10}), 201)["report_id"]
    ok(client.post(f"/reports/{rid}/validate", headers=t["admin"], json={}))

    def total(path, **q):
        return sum(ok(client.get(path, headers=t["admin"], params=q)).values())

    for path in ("/reports/validated/counts", "/reports/monitoring/counts"):
        assert total(path, barangay_id=1) >= 1
        assert total(path, barangay_id=999999) == 0
        assert total(path, disaster_type_id=999999) == 0


def test_records_entry_lists_the_receipts_of_its_deliveries(api):
    """Nov 24: a donation entry in Records names each delivery the barangay
    confirmed that carried its goods, so CSWS Main Office and the barangay
    can open "View receipt"."""
    from tests.receipt_helpers import full_counts
    client, t = api
    rid = ok(client.post("/reports/", headers=t["unit"], json={
        "disaster_type_id": 1, "barangay_id": 1, "estimated_quantity": 100}), 201)["report_id"]
    ok(client.post(f"/reports/{rid}/validate", headers=t["admin"], json={}))
    d = ok(client.post("/donations/", headers=t["donor"], json={
        "report_id": rid, "item_id": 1, "packaging": "Sack", "quantity": 40,
        "handover_method": "Drop Off"}))
    ok(client.post("/donations/receive", headers=t["csws"],
                   json={"donation_id": d["donation_id"], "actual_quantity": 40}))
    ok(client.post(f"/cmo/donations/{d['donation_id']}/confirm", headers=t["cmo"],
                   json={"status": "Confirmed"}), 201)

    def entry(who):
        rows = ok(client.get("/donations/records", headers=t[who],
                             params={"report_id": rid, "include_closed": "true",
                                     "limit": 10, "offset": 0}))
        return next(e for e in rows if any(i["donation_id"] == d["donation_id"]
                                           for i in e["items"]))

    assert entry("csws")["receipt_deliveries"] == []
    did = ok(client.post("/deliveries/", headers=t["csws"], json={
        "report_id": rid, "destination_barangay_id": 1, "delivery_date": "2026-10-01T08:00:00",
        "items": [{"item_id": 1, "quantity": 40}]}), 201)["delivery_id"]
    ok(client.post(f"/deliveries/{did}/advance", headers=t["csws"]))
    ok(client.post(f"/deliveries/{did}/advance", headers=t["csws"]))
    assert entry("csws")["receipt_deliveries"] == []          # arrived, not confirmed yet
    ok(client.post(f"/deliveries/{did}/confirm-receipt", headers=t["brgy"],
                   json=full_counts(client, did, t["brgy"])), 201)
    for who in ("csws", "brgy", "admin"):
        [r] = entry(who)["receipt_deliveries"]
        assert r["delivery_id"] == did and r["received_at"]
        assert client.get(f"/deliveries/{did}/acknowledgment", headers=t[who]).status_code == 200
