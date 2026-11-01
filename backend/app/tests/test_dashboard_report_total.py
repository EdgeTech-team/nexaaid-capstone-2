"""
Ivan (testing 9.3): the Disaster Unit dashboard's "Disaster reports" total
leaves out rejected and withdrawn reports. They still show in the
"Reports by status" breakdown.
"""
from tests.test_role_flows import api, ok  # noqa: F401  (fixture)


def _new_report(client, t):
    return ok(client.post("/reports/", headers=t["unit"], json={
        "disaster_type_id": 1, "barangay_id": 1, "estimated_quantity": 50,
    }), 201)["report_id"]


def test_total_reports_skips_rejected_and_withdrawn(api):
    client, t = api
    before = ok(client.get("/dashboard/summary", headers=t["unit"]))["total_reports"]

    pending = _new_report(client, t)
    validated = _new_report(client, t)
    ok(client.post(f"/reports/{validated}/validate", headers=t["admin"], json={}))
    rejected = _new_report(client, t)
    ok(client.post(f"/reports/{rejected}/reject", headers=t["admin"],
                   json={"rejection_reason": "Wrong barangay"}))
    withdrawn = _new_report(client, t)
    ok(client.post(f"/reports/{withdrawn}/withdraw", headers=t["unit"], json={}))

    after = ok(client.get("/dashboard/summary", headers=t["unit"]))["total_reports"]
    assert after - before == 2  # the pending and the validated one

    by_status = {
        row["status"]: row["count"]
        for row in ok(client.get("/dashboard/reports-breakdown", headers=t["unit"]))["by_status"]
    }
    assert by_status.get("Rejected", 0) >= 1
    assert pending and validated
