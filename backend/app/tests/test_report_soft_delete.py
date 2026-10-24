"""Testing 2.3: the Administrator can delete a Rejected report.

It is a soft delete: the row stays (with who rejected it and why) and every
list hides it. Only Rejected reports can be deleted.
"""
from models.report import DisasterReport


def _new_report(reporter_client, seed):
    return reporter_client.post(
        "/reports/",
        json={
            "disaster_type_id": seed["disaster_type_id"],
            "barangay_id": seed["barangay_id"],
            "description": "Report to delete.",
            # A report with no data cannot be validated (UC-A3 7a), so give it some.
            "affected_families": 5,
            "assistance_needed": "Rice",
            "estimated_quantity": 10,
            "source": "web",
        },
    ).json()["report_id"]


def _reject(admin_client, report_id):
    resp = admin_client.post(
        f"/reports/{report_id}/reject", json={"rejection_reason": "Not enough detail."}
    )
    assert resp.status_code == 200


def test_admin_deletes_rejected_report_and_it_disappears(
    admin_client, reporter_client, seed, db_session, optional_login_as_client
):
    report_id = _new_report(reporter_client, seed)
    _reject(admin_client, report_id)
    # The Administrator's report dropdown (staff only since F-01) lists it
    # while it is Rejected, so the "gone" check below is not checking an empty list.
    before = admin_client.get("/lookups").json()
    assert report_id in [r["id"] for r in before["reports"]]

    assert admin_client.delete(f"/reports/{report_id}").status_code == 204

    # Hidden everywhere it used to show.
    listed = admin_client.get("/reports/", params={"status": "Rejected"}).json()
    assert report_id not in [r["report_id"] for r in listed]
    monitoring = admin_client.get("/reports/monitoring").json()
    assert report_id not in [r["report_id"] for r in monitoring]
    assert admin_client.get(f"/reports/{report_id}").status_code == 404
    assert admin_client.delete(f"/reports/{report_id}").status_code == 404   # already gone
    # ...and out of the staff dropdowns (GET /lookups lists every report).
    lookups = admin_client.get("/lookups").json()
    assert report_id not in [r["id"] for r in lookups["reports"]]

    # ...but the row and its audit trail are still in the database.
    db_session.expire_all()
    row = db_session.get(DisasterReport, report_id)
    assert row is not None
    assert row.deleted_at is not None
    assert row.deleted_by_user_id == seed["admin_id"]
    assert row.rejection_reason == "Not enough detail."


def test_only_rejected_reports_can_be_deleted(admin_client, reporter_client, seed):
    pending = _new_report(reporter_client, seed)
    resp = admin_client.delete(f"/reports/{pending}")
    assert resp.status_code == 409 and "rejected" in resp.json()["detail"].lower()

    validated = _new_report(reporter_client, seed)
    assert admin_client.post(f"/reports/{validated}/validate", json={}).status_code == 200
    assert admin_client.delete(f"/reports/{validated}").status_code == 409

    # Neither was touched.
    assert admin_client.get(f"/reports/{pending}").status_code == 200
    assert admin_client.get(f"/reports/{validated}").status_code == 200


def test_reporter_cannot_delete_a_report(admin_client, reporter_client, seed):
    report_id = _new_report(reporter_client, seed)
    _reject(admin_client, report_id)
    assert reporter_client.delete(f"/reports/{report_id}").status_code == 403
    assert admin_client.get(f"/reports/{report_id}").status_code == 200