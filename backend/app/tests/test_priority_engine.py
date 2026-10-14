from core.priority_engine import compute_priority
from models.report import DisasterReport


def test_compute_priority_normal_case(db_session, seed):
    report = DisasterReport(
        user_id=seed["reporter_id"],
        disaster_type_id=seed["disaster_type_id"],  # this is the "Flood" type from seed
        barangay_id=seed["barangay_id"],
        sitio_id=seed["sitio_id"],
        source="web",
        status="Validated",
        affected_families=60,       # -> 75
        estimated_quantity=30,      # -> 50
        assistance_needed="Food and water",
    )

    db_session.add(report)
    db_session.commit()
    db_session.refresh(report)

    result = compute_priority(report)

    # assertions will go here
    assert result["score"] == 75.00
    assert result["priority_level"] == "High"
    assert result["recommendation"] == (
        "Priority computed without data (2a: not yet validated/fulfilled)."
    )

def test_compute_priority_insufficient_data(db_session, seed):
    report = DisasterReport(
        user_id=seed["reporter_id"],
        disaster_type_id=seed["disaster_type_id"],
        barangay_id=seed["barangay_id"],
        sitio_id=seed["sitio_id"],
        source="web",
        status="Validated",
        affected_families=None,
        estimated_quantity=None,
        assistance_needed=None,
    )

    db_session.add(report)
    db_session.commit()
    db_session.refresh(report)

    result = compute_priority(report)

    assert result["score"] is None
    assert result["priority_level"] == "Needs Review"
    assert result["recommendation"] == "Insufficient data to compute priority."


def test_admin_validate_report_computes_priority(
    admin_client, reporter_client, seed
):
    create_resp = reporter_client.post(
        "/reports/",
        json={
            "disaster_type_id": seed["disaster_type_id"],
            "barangay_id": seed["barangay_id"],
            "sitio_id": seed["sitio_id"],
            "description": "Report with priority data.",
            "source": "web",
            "affected_families": 60,
            "estimated_quantity": 30,
            "assistance_needed": "Food and water",
        },
    )

    assert create_resp.status_code == 201
    report_id = create_resp.json()["report_id"]

    resp = admin_client.post(
        f"/reports/{report_id}/validate",
        json={},
    )

    assert resp.status_code == 200

    body = resp.json()

    assert body["ai_priority_score"] is not None
    assert body["priority_level"] is not None
    assert body["ai_recommendation"] is not None
    assert body["ai_processed_at"] is not None

