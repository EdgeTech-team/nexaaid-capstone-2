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
    rid = _report(client, t)

    # UC-D2: guests see all of the barangay's methods with the note.
    res = ok(client.get(f"/reports/{rid}/donation-info"))
    assert res["source"] == "barangay" and res["info"]["provider"] == "GCash"
    assert [m["provider"] for m in res["methods"]] == ["GCash", "Bank"]
    assert res["note"] == "NexaAid does not process or verify payments. Send directly to the barangay."

    # UC-CD1: the Disaster Unit overrides it for this report only (and may keep the QR).
    override = {"provider": "Maya", "account_name": "Typhoon Relief Desk",
                "account_number": "09180000000", "qr_file_id": qr["file_id"]}
    res = ok(client.put(f"/reports/{rid}/donation-info", headers=t["unit"], json=override))
    assert res["source"] == "report" and res["info"]["provider"] == "Maya"
    assert res["methods"] == []                                    # the override replaces the list
    other_report = _report(client, t)
    assert ok(client.get(f"/reports/{other_report}/donation-info"))["source"] == "barangay"
    for key in ("brgy", "donor", "csws"):
        assert client.put(f"/reports/{rid}/donation-info", headers=t[key], json=override).status_code == 403

    # Removing the override falls back to the barangay's methods.
    assert client.delete(f"/reports/{rid}/donation-info", headers=t["unit"]).status_code == 204
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
