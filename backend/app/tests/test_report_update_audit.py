"""
F-07: PATCH /reports/{id} no longer changes a report's status (validate /
reject / withdraw / delete do, with their own checks, records and notices),
and every correction it makes is written to the audit log.
Real auth stack: the `api` fixture of tests/test_role_flows.py.
"""
from tests.test_role_flows import api, ok  # noqa: F401  (fixture)


def _report(client, t):
    return ok(client.post("/reports/", headers=t["unit"], json={
        "disaster_type_id": 1, "barangay_id": 1, "affected_families": 10,
        "estimated_quantity": 50, "description": "Flooding"}), 201)["report_id"]


def _updates(client, t, rid):
    logs = ok(client.get("/admin/audit-logs?entity_type=disaster_reports", headers=t["admin"]))
    return [l for l in logs if l["entity_id"] == rid and l["action"] == "UPDATE REPORT"]


def test_patch_cannot_change_the_status(api):
    client, t = api
    rid = _report(client, t)
    for status in ("Validated", "Rejected", "Cancelled", "Pending", "Resolved"):
        r = client.patch(f"/reports/{rid}", headers=t["admin"], json={"status": status})
        assert r.status_code == 422 and "status" in r.text, status
    report = ok(client.get(f"/reports/{rid}", headers=t["admin"]))
    assert report["status"] == "Pending" and report["validated_by"] is None
    assert _updates(client, t, rid) == []                   # nothing changed, nothing logged
    # Non-admins are still refused before anything else.
    assert client.patch(f"/reports/{rid}", headers=t["unit"], json={"description": "x"}).status_code == 403
    # The dedicated endpoint still validates it, with its own checks and record.
    ok(client.post(f"/reports/{rid}/validate", headers=t["admin"], json={}))
    report = ok(client.get(f"/reports/{rid}", headers=t["admin"]))
    assert report["status"] == "Validated" and report["validated_by"] is not None


def test_corrections_are_audit_logged(api):
    client, t = api
    rid = _report(client, t)
    res = ok(client.patch(f"/reports/{rid}", headers=t["admin"],
                          json={"description": "Flooding, Sitio 2", "affected_families": 25}))
    assert res["description"] == "Flooding, Sitio 2" and res["affected_families"] == 25
    [log] = _updates(client, t, rid)
    assert log["user"] == "testadmin@gmail.com"
    assert log["old_value"]["description"] == "Flooding"
    assert log["new_value"]["description"] == "Flooding, Sitio 2"
    assert log["old_value"]["affected_families"] == "10"
    assert log["new_value"]["affected_families"] == "25"


def test_needs_corrections_are_logged_with_old_and_new(api):
    client, t = api
    rid = _report(client, t)
    ok(client.post(f"/reports/{rid}/validate", headers=t["admin"], json={}))
    ok(client.patch(f"/reports/{rid}", headers=t["admin"], json={"estimated_quantity": 20}))
    [log] = _updates(client, t, rid)
    assert [n["quantity"] for n in log["old_value"]["needs"]] == [50]
    assert [n["quantity"] for n in log["new_value"]["needs"]] == [20]
