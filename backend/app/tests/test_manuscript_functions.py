"""
Checks the functions added to match the manuscript use cases
(UC-A1/A2/A4, UC-CM1/CM2, UC-C1/C2, UC-DR1/DR2, UC-B1/B2, section 7
dashboards). Uses the same real-auth fixture as test_role_flows.
"""
from tests.test_role_flows import api, ok, PASSWORD  # noqa: F401  (fixture)


def _validated_report_with_stock(client, t, qty=100):
    rid = ok(client.post("/reports/", headers=t["unit"], json={
        "disaster_type_id": 1, "barangay_id": 1, "estimated_quantity": qty}), 201)["report_id"]
    ok(client.post(f"/reports/{rid}/validate", headers=t["admin"], json={}))
    d = ok(client.post("/donations/", headers=t["donor"], json={
        "report_id": rid, "item_id": 1, "packaging": "Sack (50 kg)",
        "quantity": 60, "handover_method": "Drop Off"}))
    return rid, d


def test_admin_accounts_orgs_and_logs(api):
    client, t = api
    users = ok(client.get("/admin/users", headers=t["admin"]))
    donor = next(u for u in users if u["email"] == "donor.test@example.com")
    assert donor["role"] == "Individual Donor" and donor["is_active"]
    assert client.get("/admin/users", headers=t["csws"]).status_code == 403

    # UC-A1: deactivate -> cannot log in, reactivate -> can
    ok(client.patch(f"/admin/users/{donor['user_id']}", headers=t["admin"], json={"is_active": False}))
    r = client.post("/token", data={"username": "donor.test@example.com", "password": PASSWORD})
    assert r.status_code == 403 and "deactivated" in r.json()["detail"]
    assert client.get("/health/secure", headers=t["donor"]).status_code == 403  # old token rejected
    ok(client.patch(f"/admin/users/{donor['user_id']}", headers=t["admin"], json={"is_active": True}))
    ok(client.post("/token", data={"username": "donor.test@example.com", "password": PASSWORD}))

    # UC-A2: organization is Pending until approved
    org = ok(client.post("/auth/register/organization", json={
        "org_name": "Relief PH", "organization_type": "NGO", "address": "Tipolo, Mandaue",
        "contact_person": "Jo", "registration_no": "REG-9", "contact_email": "jo@relief.ph",
        "password": PASSWORD, "contact_number": "09171234567"}), 201)
    r = client.post("/token", data={"username": "jo@relief.ph", "password": PASSWORD})
    assert r.status_code == 403 and "Pending" in r.json()["detail"]
    pending = ok(client.get("/admin/organizations?status=Pending", headers=t["admin"]))
    assert pending[0]["document_missing"] is True          # UC-A2 alt 4a flag
    ok(client.post(f"/admin/organizations/{org['organization_id']}/decision",
                   headers=t["admin"], json={"decision": "Approved"}))
    ok(client.post("/token", data={"username": "jo@relief.ph", "password": PASSWORD}))

    # UC-A4: activity logs, read-only, admin only
    actions = [l["action"] for l in ok(client.get("/admin/audit-logs", headers=t["admin"]))]
    assert {"DEACTIVATE ACCOUNT", "ACTIVATE ACCOUNT", "APPROVE ORGANIZATION"} <= set(actions)
    assert client.get("/admin/audit-logs", headers=t["cmo"]).status_code == 403
    dash = ok(client.get("/dashboard/admin", headers=t["admin"]))
    assert dash["total_users"] >= 8 and dash["pending_organizations"] == 0


def test_qr_inventory_stock_and_delivery_history(api):
    client, t = api
    rid, d = _validated_report_with_stock(client, t)

    # UC-CM1 step 2: find the donation by its QR reference
    found = ok(client.get(f"/donations/by-qr/{d['qr_reference'].lower()}", headers=t["csws"]))
    assert found["donation_id"] == d["donation_id"] and found["unit"] == "kg"
    assert client.get("/donations/by-qr/DON-NOPE", headers=t["csws"]).status_code == 404
    assert client.get(f"/donations/by-qr/{d['qr_reference']}", headers=t["donor"]).status_code == 403

    # Actual quantity differs from declared (UC-CM1 alt 4a): 55 of 60
    ok(client.post("/donations/receive", headers=t["csws"],
                   json={"donation_id": d["donation_id"], "actual_quantity": 55}))
    inv = ok(client.get(f"/donations/inventory?report_id={rid}", headers=t["csws"]))
    assert inv[0]["quantity"] == 55 and inv[0]["report_label"].startswith(f"#{rid}")

    # Delivery draws from this report's stock and cannot exceed it
    body = {"report_id": rid, "destination_barangay_id": 1, "delivery_date": "2026-10-01T08:00:00",
            "items": [{"item_id": 1, "quantity": 80}]}
    r = client.post("/deliveries/", headers=t["csws"], json=body)
    assert r.status_code == 409 and "Not enough stock" in r.json()["detail"]
    body["items"][0]["quantity"] = 40
    did = ok(client.post("/deliveries/", headers=t["csws"], json=body), 201)["delivery_id"]
    assert ok(client.get(f"/donations/inventory?report_id={rid}", headers=t["csws"]))[0]["quantity"] == 15

    ok(client.post(f"/deliveries/{did}/advance", headers=t["csws"]))
    ok(client.post(f"/deliveries/{did}/advance", headers=t["csws"]))
    # UC-B1 alt 4a: acknowledge only after receipt is confirmed
    assert client.post(f"/deliveries/{did}/acknowledge", headers=t["brgy"]).status_code == 409
    ok(client.post(f"/deliveries/{did}/confirm-receipt", headers=t["brgy"], json={}), 201)
    ok(client.post(f"/deliveries/{did}/acknowledge", headers=t["brgy"]))
    assert client.post(f"/deliveries/{did}/acknowledge", headers=t["brgy"]).status_code == 409
    assert client.post(f"/deliveries/{did}/acknowledge", headers=t["brgy2"]).status_code == 404

    hist = ok(client.get(f"/deliveries/{did}/history", headers=t["csws"]))
    assert [h["action"] for h in hist["history"]] == [
        "PREPARE DELIVERY", "UPDATE DELIVERY STATUS", "UPDATE DELIVERY STATUS",
        "CONFIRM RECEIPT", "ACKNOWLEDGE AID"]
    assert hist["acknowledged"] and all(h["at"] for h in hist["history"])

    main = ok(client.get("/dashboard/csws-main", headers=t["csws"]))
    assert main["total_quantity_received"] == 55 and main["total_quantity_distributed"] == 40
    assert main["inventory_summary"] == [{"item": "Rice", "unit": "kg", "quantity": 15}]
    assert main["recent_activity"]

    b = ok(client.get("/dashboard/barangay", headers=t["brgy"]))
    assert b["acknowledged"] == 1 and b["reports"][0]["total_items_delivered"] == 40
    assert ok(client.get("/dashboard/barangay", headers=t["brgy2"]))["donations_linked"] == 0


def test_cmo_hold_revert_and_drrmo_completion(api):
    client, t = api
    rid, d = _validated_report_with_stock(client, t)
    did_ = d["donation_id"]
    # CMO can only confirm goods CSWS actually received
    assert client.post(f"/cmo/donations/{did_}/confirm", headers=t["cmo"],
                       json={"status": "Confirmed"}).status_code == 400
    ok(client.post("/donations/receive", headers=t["csws"],
                   json={"donation_id": did_, "actual_quantity": 60}))
    ok(client.post(f"/cmo/donations/{did_}/confirm", headers=t["cmo"],
                   json={"status": "On Hold", "notes": "check receipt"}), 201)
    row = ok(client.get("/cmo/donations/pending", headers=t["cmo"]))[0]
    assert row["cmo_decision"] == "On Hold" and not row["officially_recognized"]
    assert ok(client.get("/cmo/dashboard", headers=t["cmo"]))["on_hold"] == 1
    ok(client.post(f"/cmo/donations/{did_}/confirm", headers=t["cmo"], json={"status": "Confirmed"}), 201)
    assert ok(client.get("/cmo/donations/confirmed", headers=t["cmo"]))[0]["officially_recognized"]
    # Alt 4a: reverse the confirmation
    ok(client.post(f"/cmo/donations/{did_}/revert", headers=t["cmo"]))
    assert ok(client.get("/cmo/donations/pending", headers=t["cmo"]))[0]["status"] == "Received"

    # DRRMO: accept -> in transit -> completed with a summary
    delivery = ok(client.post("/deliveries/", headers=t["csws"], json={
        "report_id": rid, "destination_barangay_id": 1, "delivery_date": "2026-10-01T08:00:00",
        "items": [{"item_id": 1, "quantity": 30}]}), 201)
    req = ok(client.post("/logistics/requests", headers=t["csws"],
                         json={"delivery_id": delivery["delivery_id"], "notes": "1 truck"}), 201)
    rid_ = req["request_id"]
    assert client.patch(f"/drrmo/requests/{rid_}/complete", headers=t["drrmo"],
                        json={"summary": "done"}).status_code == 400   # not accepted yet
    ok(client.patch(f"/drrmo/requests/{rid_}/accept", headers=t["drrmo"],
                    json={"scheduled_date": "2026-10-02T08:00:00"}))
    ok(client.post(f"/deliveries/{delivery['delivery_id']}/advance", headers=t["csws"]))
    dash = ok(client.get("/drrmo/dashboard", headers=t["drrmo"]))
    assert (dash["scheduled"], dash["in_transit"]) == (0, 1)
    assert client.patch(f"/drrmo/requests/{rid_}/complete", headers=t["drrmo"],
                        json={"summary": ""}).status_code == 422   # alt 6a: summary required
    done = ok(client.patch(f"/drrmo/requests/{rid_}/complete", headers=t["drrmo"],
                           json={"summary": "Delivered by truck 2"}))
    assert done["status"] == "Completed" and "30 kg Rice" in done["notes"]
    assert ok(client.get("/drrmo/dashboard", headers=t["drrmo"]))["completed"] == 1
    # CSWS sees the request's status
    assert ok(client.get("/logistics/requests", headers=t["csws"]))[0]["status"] == "Completed"


def test_session_login_endpoints_after_merge(api):
    client, t = api
    r = ok(client.post("/auth/login", json={"email": "CSWS.test@example.com", "password": PASSWORD}))
    assert r["user"]["role_name"] == "CSWS Main Office"
    me = ok(client.get("/auth/me", headers={"Authorization": f"Bearer {r['access_token']}"}))
    assert me["email"] == "csws.test@example.com"
    assert client.post("/auth/login", json={"email": "csws.test@example.com",
                                            "password": "wrong"}).status_code == 401


def test_appendix_h_module_access(api):
    """Appendix H: who may use which module."""
    client, t = api
    report_id, d = _validated_report_with_stock(client, t)
    ok(client.post("/donations/receive", headers=t["csws"],
                   json={"donation_id": d["donation_id"], "actual_quantity": 60}))
    priority = ok(client.get(f"/reports/{report_id}", headers=t["admin"]))["priority_level"]

    # 2.4 View Validated Reports: every role.
    for role in ("admin", "donor", "csws", "unit", "cmo", "drrmo", "brgy", "brgy2"):
        rows = ok(client.get("/reports/validated", headers=t[role]))
        assert [r["report_id"] for r in rows] == [report_id], role
    # 3.3 Priority-based filtering.
    assert ok(client.get("/reports/validated", params={"priority_level": priority}, headers=t["donor"]))
    other = "Low" if priority != "Low" else "High"
    assert ok(client.get("/reports/validated", params={"priority_level": other}, headers=t["donor"])) == []

    # 2.5 Monitor Report Status: Admin, Main Office, Disaster Unit.
    for role in ("admin", "csws", "unit"):
        ok(client.get("/reports/monitoring", headers=t[role]))
    for role in ("donor", "drrmo", "cmo"):
        ok(client.get("/reports/monitoring", headers=t[role]), 403)

    # 2.2 SMS-based reporting: Disaster Unit only.
    sms = {"contact_number": "09171234567", "raw_message": "FLOOD 5FAM",
           "disaster_type_id": 1, "barangay_id": 1}
    for role in ("admin", "csws", "donor"):
        ok(client.post("/reports/sms", json=sms, headers=t[role]), 403)
    created = ok(client.post("/reports/sms", json=sms, headers=t["unit"]), 201)
    assert created["report"]["source"] == "SMS"

    # 4.4 / 4.5 Donation records: Admin, Main Office, CMO.
    for role in ("admin", "csws", "cmo"):
        rows = ok(client.get("/donations/records", headers=t[role]))
        assert rows and rows[0]["donor"]
    ok(client.get("/donations/records", headers=t["drrmo"]), 403)

    # 6.3 Donation summaries per report: CMO and Admin.
    for role in ("cmo", "admin"):
        assert ok(client.get("/cmo/dashboard", headers=t[role]))["per_report"]
    ok(client.get("/cmo/dashboard", headers=t["csws"]), 403)

    # 8.5 View Delivery Records: Admin, Main Office, DRRMO, Barangay.
    for role in ("admin", "csws", "drrmo", "brgy"):
        ok(client.get("/deliveries/", headers=t[role]))
    ok(client.get("/deliveries/", headers=t["donor"]), 403)
