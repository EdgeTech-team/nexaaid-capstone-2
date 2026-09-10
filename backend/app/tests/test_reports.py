"""
backend/app/tests/test_reports.py

Tests for Module 3.4 — Report Management.

Covers the flows your Capstone doc actually specifies:
- UC-02 success path: reporter submits -> saved as Pending
- UC-02 extension 2a: missing required field is rejected
- UC-02 step 6: admin validates -> status=Validated, validated_by recorded
- UC-02 extension 5a: admin rejects -> status=Rejected, reason recorded
- Access control: non-admin can't validate/reject; a reporter can't list all reports
- FR 2.4: SMS ingestion creates a report + linked sms_report_metadata together
"""


def test_create_report_success(reporter_client, seed):
    payload = {
        "disaster_type_id": seed["disaster_type_id"],
        "barangay_id": seed["barangay_id"],
        "sitio_id": seed["sitio_id"],
        "description": "Flooding along the main road.",
        "affected_families": 12,
        "assistance_needed": "Food packs, drinking water",
        "estimated_quantity": 50,
        "source": "web",
    }
    resp = reporter_client.post("/reports/", json=payload)

    assert resp.status_code == 201
    body = resp.json()
    assert body["status"] == "Pending"          # UC-02 step 4
    assert body["user_id"] == seed["reporter_id"]
    assert body["validated_by"] is None
    assert body["rejection_reason"] is None


def test_create_report_missing_required_field_rejected(reporter_client, seed):
    # UC-02 extension 2a: "System prevents submission until required
    # fields are filled." disaster_type_id is required — omit it.
    payload = {
        "barangay_id": seed["barangay_id"],
        "description": "Missing disaster type.",
        "source": "web",
    }
    resp = reporter_client.post("/reports/", json=payload)
    assert resp.status_code == 422  # FastAPI/Pydantic validation error


def test_reporter_cannot_list_all_reports(reporter_client):
    # list_reports is staff-only (require_role); a plain "citizen" role
    # submitter should be forbidden.
    resp = reporter_client.get("/reports/")
    assert resp.status_code == 403


def test_admin_validate_report(admin_client, reporter_client, seed):
    create_resp = reporter_client.post(
        "/reports/",
        json={
            "disaster_type_id": seed["disaster_type_id"],
            "barangay_id": seed["barangay_id"],
            "description": "Report to validate.",
            "source": "web",
        },
    )
    report_id = create_resp.json()["report_id"]

    resp = admin_client.post(f"/reports/{report_id}/validate", json={})

    assert resp.status_code == 200
    body = resp.json()
    assert body["status"] == "Validated"                    # UC-02 step 6/7
    assert body["validated_by"] == seed["admin_id"]          # SD4 audit field


def test_admin_reject_report_requires_reason(admin_client, reporter_client, seed):
    create_resp = reporter_client.post(
        "/reports/",
        json={
            "disaster_type_id": seed["disaster_type_id"],
            "barangay_id": seed["barangay_id"],
            "description": "Report to reject.",
            "source": "web",
        },
    )
    report_id = create_resp.json()["report_id"]

    # Missing rejection_reason -> validation error (UC-02 5a requires
    # the rep get specific feedback, so a blank reason isn't allowed)
    resp = admin_client.post(f"/reports/{report_id}/reject", json={})
    assert resp.status_code == 422

    resp = admin_client.post(
        f"/reports/{report_id}/reject",
        json={"rejection_reason": "Missing field evidence photos."},
    )
    assert resp.status_code == 200
    body = resp.json()
    assert body["status"] == "Rejected"
    assert body["rejection_reason"] == "Missing field evidence photos."
    assert body["validated_by"] == seed["admin_id"]


def test_reporter_cannot_validate_report(reporter_client, seed):
    create_resp = reporter_client.post(
        "/reports/",
        json={
            "disaster_type_id": seed["disaster_type_id"],
            "barangay_id": seed["barangay_id"],
            "description": "Should not be validatable by reporter.",
            "source": "web",
        },
    )
    report_id = create_resp.json()["report_id"]

    resp = reporter_client.post(f"/reports/{report_id}/validate", json={})
    assert resp.status_code == 403


def test_sms_ingest_creates_report_and_metadata(admin_client, seed):
    # FR 2.4: SMS reports are reviewed and manually encoded by staff.
    payload = {
        "contact_number": "09171234567",
        "raw_message": "FLOOD BRGY TEST 5FAM FOOD WATER",
        "disaster_type_id": seed["disaster_type_id"],
        "barangay_id": seed["barangay_id"],
        "affected_families": 5,
        "assistance_needed": "Food, water",
    }
    resp = admin_client.post("/reports/sms", json=payload)

    assert resp.status_code == 201
    body = resp.json()
    assert body["report"]["source"] == "sms"
    assert body["report"]["status"] == "Pending"
    assert body["sms_metadata"]["raw_message"] == payload["raw_message"]
    assert body["sms_metadata"]["report_id"] == body["report"]["report_id"]