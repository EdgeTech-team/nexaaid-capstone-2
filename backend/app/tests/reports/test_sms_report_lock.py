"""J7 / NF-012 (team agreement Nov 18, 2026, A5): SMS reports are locked.

Done when (task brief J7):
  - a PATCH on an SMS report = 409
  - app reports are still editable
  - the raw SMS is visible on validation
Also: raw_message is never editable (PATCH and the reporter's PUT /mine
are refused for SMS reports, the stored SMS stays as received); every
encode and validate is audit-logged with the Administrator's name; the
role checks (only the Administrator patches; only the Administrator and the
Disaster Unit read the raw SMS).
Real auth stack: the `api` fixture of tests/general/test_role_flows.py.
"""
from tests.general.test_role_flows import api, ok  # noqa: F401  (fixture)

SMS = {"contact_number": "+63 917 000 0000",          # the Disaster Unit member's number
       "raw_message": "FLOOD BRGY1 5FAM RICE",
       "disaster_type_id": 1, "barangay_id": 1, "affected_families": 5,
       "description": "Flooding"}
LOCKED = "Reject it with a reason so the Disaster Unit can resend"
EDIT = {"disaster_type_id": 1, "barangay_id": 1, "affected_families": 9,
        "description": "Changed after saving"}


# ------------------------------------------------------------------ helpers
def _encode(client, t, **over):
    """An Administrator encodes an SMS. Returns (report, sms_metadata)."""
    from tests.pickup.test_pickup_days_and_runs import _activate_everyone
    _activate_everyone()          # SQLite stores is_active as text
    made = ok(client.post("/reports/sms", headers=t["admin"], json={**SMS, **over}), 201)
    return made["report"], made["sms_metadata"]


def _app_report(client, t):
    return ok(client.post("/reports/", headers=t["unit"], json={
        "disaster_type_id": 1, "barangay_id": 1, "affected_families": 10,
        "estimated_quantity": 50, "description": "Flooding", "source": "Mobile"}), 201)["report_id"]


def _logs(client, t, rid, action):
    rows = ok(client.get("/admin/audit-logs?entity_type=disaster_reports", headers=t["admin"]))
    return [r for r in rows if r["entity_id"] == rid and r["action"] == action]


# ------------------------------------------ Done when: PATCH on SMS = 409
def test_a_patch_on_an_sms_report_is_409(api):
    client, t = api
    report, _ = _encode(client, t)
    rid = report["report_id"]
    for body in ({"description": "Typo fixed"}, {"affected_families": 50},
                 {"estimated_quantity": 10}, {"raw_message": "FLOOD 50FAM"}):
        r = client.patch(f"/reports/{rid}", headers=t["admin"], json=body)
        assert r.status_code == 409 and LOCKED in r.json()["detail"], body
    after = ok(client.get(f"/reports/{rid}", headers=t["admin"]))
    assert (after["description"], after["affected_families"]) == ("Flooding", 5)
    assert _logs(client, t, rid, "UPDATE REPORT") == []

    # Still locked once validated; rejecting with a reason still works.
    ok(client.post(f"/reports/{rid}/validate", headers=t["admin"], json={}))
    assert client.patch(f"/reports/{rid}", headers=t["admin"],
                        json={"description": "x"}).status_code == 409
    second, _ = _encode(client, t)
    ok(client.post(f"/reports/{second['report_id']}/reject", headers=t["admin"],
                   json={"rejection_reason": "Families count unclear, please resend"}))
    assert client.patch(f"/reports/{second['report_id']}", headers=t["admin"],
                        json={"description": "x"}).status_code == 409


# ------------------------------------------- raw_message is never editable
def test_the_sms_and_its_report_cannot_be_edited_by_the_reporter_either(api):
    client, t = api
    report, meta = _encode(client, t)
    rid = report["report_id"]
    # Filed under the Disaster Unit member who sent it: their PUT /mine is refused.
    r = client.put(f"/reports/{rid}/mine", headers=t["unit"],
                   json={**EDIT, "raw_message": "FLOOD 9FAM"})
    assert r.status_code == 409 and LOCKED in r.json()["detail"]
    # Not even after a rejection: the Disaster Unit resends instead.
    ok(client.post(f"/reports/{rid}/reject", headers=t["admin"],
                   json={"rejection_reason": "Please resend with the sitio"}))
    assert client.put(f"/reports/{rid}/mine", headers=t["unit"], json=EDIT).status_code == 409

    # An unknown sender's SMS is filed under the encoding Administrator: also locked.
    other, _ = _encode(client, t, contact_number="09998887777",
                       unregistered_sender_reason="Relayed by a barangay")   # J8
    assert client.put(f"/reports/{other['report_id']}/mine", headers=t["admin"],
                      json=EDIT).status_code == 409

    stored = ok(client.get(f"/reports/{rid}/sms-metadata", headers=t["admin"]))
    assert stored["raw_message"] == meta["raw_message"] == SMS["raw_message"]
    assert ok(client.get(f"/reports/{rid}", headers=t["admin"]))["affected_families"] == 5
    # Withdrawing (not an edit) still works for the sender.
    third, _ = _encode(client, t)
    assert ok(client.post(f"/reports/{third['report_id']}/withdraw",
                          headers=t["unit"], json={}))["status"] == "Cancelled"


# ------------------------------------ Done when: app reports still editable
def test_app_reports_are_still_editable(api):
    client, t = api
    rid = _app_report(client, t)
    fixed = ok(client.patch(f"/reports/{rid}", headers=t["admin"],
                            json={"description": "Flooding, Sitio 2"}))
    assert fixed["description"] == "Flooding, Sitio 2"
    mine = ok(client.put(f"/reports/{rid}/mine", headers=t["unit"],
                         json={**EDIT, "estimated_quantity": 30}))
    assert (mine["description"], mine["affected_families"]) == ("Changed after saving", 9)
    ok(client.post(f"/reports/{rid}/validate", headers=t["admin"], json={}))
    assert ok(client.patch(f"/reports/{rid}", headers=t["admin"],
                           json={"affected_families": 12}))["affected_families"] == 12
    assert len(_logs(client, t, rid, "UPDATE REPORT")) == 2


# --------------------------------- Done when: raw SMS visible on validation
def test_the_raw_sms_is_visible_on_validation(api):
    client, t = api
    report, _ = _encode(client, t)
    rid = report["report_id"]
    queue = ok(client.get("/reports/", headers=t["admin"], params={"status": "Pending"}))
    row = next(r for r in queue if r["report_id"] == rid)
    assert row["source"] == "SMS"                       # the screen knows to show the SMS
    meta = ok(client.get(f"/reports/{rid}/sms-metadata", headers=t["admin"]))
    assert (meta["raw_message"], meta["contact_number"]) == (SMS["raw_message"], SMS["contact_number"])
    assert meta["encoded_by_user_id"] and meta["encoded_at"]
    # The encoded fields sit beside it, unchanged.
    assert (row["affected_families"], row["description"]) == (5, "Flooding")
    # An app report has no SMS.
    assert client.get(f"/reports/{_app_report(client, t)}/sms-metadata",
                      headers=t["admin"]).status_code == 404


# -------------------------------- encode and validate logged with the name
def test_encode_and_validate_are_audit_logged_with_the_admins_name(api):
    client, t = api
    report, _ = _encode(client, t)
    rid = report["report_id"]
    [encode] = _logs(client, t, rid, "ENCODE SMS REPORT")
    new = encode["new_value"]
    assert new["encoded_by"] == "admin Test" and new["source"] == "SMS"
    assert (new["raw_message"], new["contact_number"]) == (SMS["raw_message"], SMS["contact_number"])
    assert new["affected_families"] == 5 and new["filed_under_user_id"] == report["user_id"]

    ok(client.post(f"/reports/{rid}/validate", headers=t["admin"], json={}))
    [validate] = _logs(client, t, rid, "VALIDATE REPORT")
    assert validate["old_value"] == {"status": "Pending"}
    assert validate["new_value"]["validated_by"] == "admin Test"
    assert validate["new_value"]["source"] == "SMS"

    # A rejected report validated later logs its real old status.
    again, _ = _encode(client, t)
    ok(client.post(f"/reports/{again['report_id']}/reject", headers=t["admin"],
                   json={"rejection_reason": "Check the count"}))
    ok(client.post(f"/reports/{again['report_id']}/validate", headers=t["admin"], json={}))
    [later] = _logs(client, t, again["report_id"], "VALIDATE REPORT")
    assert later["old_value"] == {"status": "Rejected"}

    text = str([encode, validate, later]).lower()
    assert "hash" not in text and "signature" not in text and "handover" not in text


# ------------------------------------------------------------- who may
def test_role_checks(api):
    client, t = api
    report, _ = _encode(client, t)
    rid = report["report_id"]
    for who in ("unit", "csws", "brgy", "donor", "cmo", "drrmo"):
        assert client.patch(f"/reports/{rid}", headers=t[who],
                            json={"description": "x"}).status_code == 403, who
        assert client.post("/reports/sms", headers=t[who], json=SMS).status_code == 403, who
    for who in ("csws", "brgy", "donor", "cmo", "drrmo"):
        assert client.get(f"/reports/{rid}/sms-metadata", headers=t[who]).status_code == 403, who
    ok(client.get(f"/reports/{rid}/sms-metadata", headers=t["unit"]))       # the sender's office
    # Someone else's report: 403 before the SMS lock.
    assert client.put(f"/reports/{rid}/mine", headers=t["csws"], json=EDIT).status_code == 403
