"""
Barangay donation-sending info (adviser item 7). DISPLAY ONLY: NexaAid
never processes or verifies money (Scope Limitation #5).

- A barangay can publish several payment methods (J3), each with its own QR.
- The Barangay Receiving Representative edits THEIR barangay only (like
  UC-B1 alt 3a); the Administrator edits any.
- UC-CD1: the CSWS Disaster Unit may override it for one report.
- UC-D2: a validated report shows the info to everyone, guests included.
"""
from tests.reg_helpers import png, upload
from tests.test_role_flows import api, ok  # noqa: F401  (fixture)


import core.database as database
from core.auth import hash_password
from models.user_rbac_model import User
from tests.reg_helpers import png, upload
from tests.test_role_flows import PASSWORD, api, ok  # noqa: F401  (fixture)

METHODS = "/barangays/{}/donation-info/methods"

GCASH = {"provider": "GCash", "account_name": "Barangay Test Relief Fund",
         "account_number": "+63 917 555 0101",
         "instructions": "Put your name and the report number in the message."}
MAYA = {"provider": "Maya", "account_name": "Barangay Test Maya",
        "account_number": "09180000001"}
BANK = {"provider": "Bank", "account_name": "Brgy Test",
        "account_number": "0012-3456-7890"}


def _report(client, t, validate=True, barangay_id=1):
    rid = ok(client.post("/reports/", headers=t["unit"], json={
        "disaster_type_id": 1, "barangay_id": barangay_id, "estimated_quantity": 10}), 201)["report_id"]
    if validate:
        ok(client.post(f"/reports/{rid}/validate", headers=t["admin"], json={}))
    return rid


def test_rep_manages_own_barangay_only_admin_any(api):
    client, t = api
    res = ok(client.post(METHODS.format(1), headers=t["brgy"], json=GCASH), 201)
    assert res["account_number"] == "09175550101"        # stored as 09...
    mid = res["method_id"]
    note = ok(client.get("/barangays/1/donation-info"))["note"]
    assert note.startswith("NexaAid does not process or verify payments")

    r = client.post(METHODS.format(2), headers=t["brgy"], json=GCASH)
    assert r.status_code == 403 and "assigned barangay" in r.text
    assert client.delete(f"{METHODS.format(2)}/{mid}", headers=t["brgy"]).status_code == 403
    ok(client.post(METHODS.format(2), headers=t["admin"],
                   json={"instructions": "Bring cash donations to the barangay hall."}), 201)
    for key in ("donor", "csws", "unit", "cmo", "drrmo"):
        assert client.post(METHODS.format(1), headers=t[key], json=GCASH).status_code == 403
    assert client.post(METHODS.format(1), json=GCASH).status_code == 401
    assert client.post(METHODS.format(99), headers=t["admin"], json=GCASH).status_code == 404

    # Public read (the first method is also returned as "info"), and the audit log.
    pub = ok(client.get("/barangays/1/donation-info"))
    assert pub["methods"][0]["provider"] == "GCash" and pub["info"]["provider"] == "GCash"
    logs = ok(client.get("/admin/audit-logs?entity_type=barangay_donation_method", headers=t["admin"]))
    assert {l["action"] for l in logs} == {"UPDATE DONATION INFO"}

    assert client.delete(f"{METHODS.format(1)}/{mid}", headers=t["brgy"]).status_code == 204
    pub = ok(client.get("/barangays/1/donation-info"))
    assert pub["methods"] == [] and pub["info"] is None


def test_several_methods_per_barangay(api):
    client, t = api
    qr1 = upload(client, "barangay_donation_qr", headers=t["brgy"])
    qr2 = upload(client, "barangay_donation_qr", png("blue"), headers=t["brgy"])
    m1 = ok(client.post(METHODS.format(1), headers=t["brgy"],
                        json={**GCASH, "qr_file_id": qr1["file_id"]}), 201)
    m2 = ok(client.post(METHODS.format(1), headers=t["brgy"],
                        json={**MAYA, "qr_file_id": qr2["file_id"]}), 201)
    m3 = ok(client.post(METHODS.format(1), headers=t["brgy"], json=BANK), 201)
    assert len({m1["method_id"], m2["method_id"], m3["method_id"]}) == 3

    pub = ok(client.get("/barangays/1/donation-info"))
    assert [m["provider"] for m in pub["methods"]] == ["GCash", "Maya", "Bank"]
    assert pub["methods"][0]["qr_url"] == qr1["url"]
    assert pub["methods"][1]["qr_url"] == qr2["url"]
    assert pub["methods"][2]["qr_url"] is None
    assert pub["info"]["provider"] == "GCash"                    # first one, for older clients

    # Edit one: the others stay as they were.
    res = ok(client.put(f"{METHODS.format(1)}/{m2['method_id']}", headers=t["brgy"],
                        json={**MAYA, "account_name": "Renamed Maya Fund",
                              "qr_file_id": qr2["file_id"]}))
    assert res["account_name"] == "Renamed Maya Fund"
    pub = ok(client.get("/barangays/1/donation-info"))
    assert [m["account_name"] for m in pub["methods"]][::2] == [
        "Barangay Test Relief Fund", "Brgy Test"]

    # Delete one: the other two remain.
    assert client.delete(f"{METHODS.format(1)}/{m1['method_id']}", headers=t["brgy"]).status_code == 204
    pub = ok(client.get("/barangays/1/donation-info"))
    assert [m["provider"] for m in pub["methods"]] == ["Maya", "Bank"]

    # A method of another barangay, or one that does not exist, is a 404 for this barangay.
    other = ok(client.post(METHODS.format(2), headers=t["admin"], json=BANK), 201)
    r = client.put(f"{METHODS.format(1)}/{other['method_id']}", headers=t["brgy"], json=BANK)
    assert r.status_code == 404
    assert client.delete(f"{METHODS.format(1)}/{other['method_id']}", headers=t["brgy"]).status_code == 404
    assert client.put(f"{METHODS.format(1)}/9999", headers=t["brgy"], json=BANK).status_code == 404


def test_validation(api):
    client, t = api
    bad = [
        {},                                                        # nothing at all
        {"account_number": "09175550101"},                         # no provider / name
        {"provider": "GCash", "account_number": "09175550101"},    # no account name
        {"provider": "GCash", "account_name": "Fund", "account_number": "12345"},
        {"provider": "Bank", "account_name": "Fund", "account_number": "12-ab"},
        {"provider": "PayPal", "instructions": "Send here please"},
        {"instructions": "x" * 501},
        {"qr_file_id": "short"},
    ]
    for body in bad:
        assert client.post(METHODS.format(1), headers=t["brgy"],
                           json=body).status_code == 422, body
    ok(client.post(METHODS.format(1), headers=t["brgy"], json=BANK), 201)


def test_qr_only_and_qr_ownership(api):
    client, t = api
    qr = upload(client, "barangay_donation_qr", headers=t["brgy"])
    res = ok(client.post(METHODS.format(1), headers=t["brgy"],
                         json={"qr_file_id": qr["file_id"]}), 201)    # not always text
    assert res["qr_url"] == qr["url"]
    assert client.get(qr["url"]).status_code == 200                   # public image

    # Someone else's QR, or a file of another purpose, can't be linked.
    other = upload(client, "barangay_donation_qr", png("blue"), headers=t["brgy2"])
    r = client.post(METHODS.format(1), headers=t["brgy"], json={"qr_file_id": other["file_id"]})
    assert r.status_code == 400
    idf = upload(client, "id_front")
    r = client.post(METHODS.format(1), headers=t["brgy"], json={"qr_file_id": idf["file_id"]})
    assert r.status_code == 400
    # Keeping the QR already on the method while editing the text is fine.
    ok(client.put(f"{METHODS.format(1)}/{res['method_id']}", headers=t["brgy"],
                  json={"qr_file_id": qr["file_id"], "instructions": "Scan with GCash or Maya."}))


def test_report_shows_default_override_and_guest_access(api):
    client, t = api
    qr = upload(client, "barangay_donation_qr", headers=t["brgy"])
    ok(client.post(METHODS.format(1), headers=t["brgy"],
                   json={**GCASH, "qr_file_id": qr["file_id"]}), 201)
    ok(client.post(METHODS.format(1), headers=t["brgy"], json=BANK), 201)
    rid = _report(client, t, validate=False)

    # UC-CD1: the Disaster Unit overrides it for its own report, before
    # validation (F-04), and may keep the barangay's QR.
    override = {"provider": "Maya", "account_name": "Typhoon Relief Desk",
                "account_number": "09180000000", "qr_file_id": qr["file_id"]}
    res = ok(client.put(f"/reports/{rid}/donation-info", headers=t["unit"], json=override))
    assert res["source"] == "report" and res["info"]["provider"] == "Maya"
    assert res["methods"] == []                                    # the override replaces the list
    for key in ("brgy", "donor", "csws"):
        assert client.put(f"/reports/{rid}/donation-info", headers=t[key], json=override).status_code == 403
    ok(client.post(f"/reports/{rid}/validate", headers=t["admin"], json={}))

    # UC-D2: guests see the override on this report, and the barangay's
    # methods (with the note) on any other.
    assert ok(client.get(f"/reports/{rid}/donation-info"))["source"] == "report"
    other_report = _report(client, t)
    res = ok(client.get(f"/reports/{other_report}/donation-info"))
    assert res["source"] == "barangay" and res["info"]["provider"] == "GCash"
    assert [m["provider"] for m in res["methods"]] == ["GCash", "Bank"]
    assert res["note"] == "NexaAid does not process or verify payments. Send directly to the barangay."

    # Removing the override falls back to the barangay's methods. The report
    # is validated, so only the Administrator can do it now (F-04).
    assert client.delete(f"/reports/{rid}/donation-info", headers=t["unit"]).status_code == 409
    assert client.delete(f"/reports/{rid}/donation-info", headers=t["admin"]).status_code == 204
    res = ok(client.get(f"/reports/{rid}/donation-info"))
    assert res["source"] == "barangay" and len(res["methods"]) == 2


    # A report not yet validated is hidden from guests and donors, visible to staff.
    pending = _report(client, t, validate=False)
    assert client.get(f"/reports/{pending}/donation-info").status_code == 404
    assert client.get(f"/reports/{pending}/donation-info", headers=t["donor"]).status_code == 404
    assert ok(client.get(f"/reports/{pending}/donation-info", headers=t["unit"]))["source"] == "barangay"
    assert client.get("/reports/9999/donation-info").status_code == 404

    # A barangay with nothing set: no methods, still the note.
    rid2 = _report(client, t, barangay_id=2)
    res = ok(client.get(f"/reports/{rid2}/donation-info"))
    assert res["info"] is None and res["methods"] == [] and res["source"] is None and res["note"]


def test_other_provider_needs_its_own_name(api):
    """Testing 2.1: choosing "Other" asks for the provider's name; any other
    provider ignores it."""
    client, t = api
    other = {"provider": "Other", "account_name": "Brgy Test",
             "account_number": "123456789"}
    # "Other" without a name is rejected, blank or missing.
    for extra in ({}, {"provider_other": "  "}, {"provider_other": "x"}):
        assert client.post(METHODS.format(1), headers=t["brgy"],
                           json={**other, **extra}).status_code == 422, extra
    res = ok(client.post(METHODS.format(1), headers=t["brgy"],
                         json={**other, "provider_other": "  Coins.ph  "}), 201)
    assert res["provider"] == "Other" and res["provider_other"] == "Coins.ph"
    pub = ok(client.get("/barangays/1/donation-info"))
    assert pub["methods"][0]["provider_other"] == "Coins.ph"

    # A name sent with a normal provider is dropped, not stored.
    res = ok(client.post(METHODS.format(1), headers=t["brgy"],
                         json={**GCASH, "provider_other": "Coins.ph"}), 201)
    assert res["provider"] == "GCash" and res["provider_other"] is None



def test_f04_report_payment_info_owner_before_validation_or_admin(api):
    """F-04: a Disaster Unit member changes a report's payment details only on
    a report they submitted, and only before it is validated; after that only
    the Administrator can. A withdrawn report is refused, a deleted one is gone."""
    client, t = api
    db = database.SessionLocal()
    try:
        db.add(User(first_name="other", last_name="Test", contact_number="09170000000",
                    email="unit2.test@example.com", password_hash=hash_password(PASSWORD),
                    role_id=6))                                     # CSWS Disaster Unit
        db.commit()
    finally:
        db.close()
    login = ok(client.post("/token", data={"username": "unit2.test@example.com",
                                           "password": PASSWORD}))
    unit2 = {"Authorization": f"Bearer {login['access_token']}"}
    path = "/reports/{}/donation-info"
    info = {"provider": "GCash", "account_name": "Typhoon Relief Desk",
            "account_number": "09180000000"}

    report = _report(client, t, validate=False)
    # Another Disaster Unit member: refused, nothing saved.
    assert client.put(path.format(report), headers=unit2, json=info).status_code == 403
    assert client.delete(path.format(report), headers=unit2).status_code == 403
    assert ok(client.get(path.format(report), headers=t["unit"]))["source"] is None
    # The submitter sets it while Pending; it is what donors see once validated.
    ok(client.put(path.format(report), headers=t["unit"], json=info))
    ok(client.post(f"/reports/{report}/validate", headers=t["admin"], json={}))
    assert ok(client.get(path.format(report)))["info"]["account_number"] == "09180000000"

    # Validated: the submitter can no longer swap or remove it; the Administrator can.
    swap = {**info, "account_number": "09189999999"}
    assert client.put(path.format(report), headers=t["unit"], json=swap).status_code == 409
    assert client.delete(path.format(report), headers=t["unit"]).status_code == 409
    assert ok(client.get(path.format(report)))["info"]["account_number"] == "09180000000"
    ok(client.put(path.format(report), headers=t["admin"], json=swap))
    assert ok(client.get(path.format(report)))["info"]["account_number"] == "09189999999"

    # Rejected (being corrected): the submitter may still set it.
    rejected = _report(client, t, validate=False)
    ok(client.post(f"/reports/{rejected}/reject", headers=t["admin"],
                   json={"rejection_reason": "Fix the numbers"}))
    ok(client.put(path.format(rejected), headers=t["unit"], json=info))

    # Withdrawn: refused for the submitter. Deleted: refused for everyone.
    withdrawn = _report(client, t, validate=False)
    ok(client.post(f"/reports/{withdrawn}/withdraw", headers=t["unit"], json={}))
    assert client.put(path.format(withdrawn), headers=t["unit"], json=info).status_code == 409
    deleted = _report(client, t, validate=False)
    ok(client.post(f"/reports/{deleted}/reject", headers=t["admin"],
                   json={"rejection_reason": "Duplicate"}))
    assert client.delete(f"/reports/{deleted}", headers=t["admin"]).status_code == 204
    assert client.put(path.format(deleted), headers=t["admin"], json=info).status_code == 404
