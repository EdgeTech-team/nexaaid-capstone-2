from core.priority_engine import compute_priority
from models.report import DisasterReport, ReportFulfillment


def test_compute_priority_normal_case(db_session, seed):
    report = DisasterReport(
        user_id=seed["reporter_id"],
        disaster_type_id=seed["disaster_type_id"],  # this is the "Flood" type from seed
        barangay_id=seed["barangay_id"],
        sitio_id=seed["sitio_id"],
        source="web",
        status="Validated",
        affected_families=60,       # -> 75
        estimated_quantity=30,      # no longer a factor (option A, Oct 2026)
        assistance_needed="Food and water",
    )

    db_session.add(report)
    db_session.commit()
    db_session.refresh(report)

    result = compute_priority(report)

    # assertions will go here
    # Option A: families 75*0.40 + Flood 70*0.30 + unmet 100*0.30 = 81
    assert result["score"] == 81.00
    assert result["priority_level"] == "Critical"
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



def _validated_flood_report(db_session, seed, status):
    report = DisasterReport(
        user_id=seed["reporter_id"],
        disaster_type_id=seed["disaster_type_id"],  # Flood, severity 70
        barangay_id=seed["barangay_id"],
        sitio_id=seed["sitio_id"],
        source="web",
        status="Validated",
        affected_families=100,      # -> 100
        estimated_quantity=100,     # not a factor (option A)
        assistance_needed="Rice",
    )
    db_session.add(report)
    db_session.flush()
    db_session.add(ReportFulfillment(
        report_id=report.report_id, total_items_needed=100, verification_status=status))
    db_session.commit()
    db_session.refresh(report)
    return report


def test_fully_fulfilled_report_drops_to_low(db_session, seed):
    """Testing, Module 3: with the old weights this report still scored 67.5
    (High) at 100% fulfillment, so it kept asking for donations."""
    partial = compute_priority(_validated_flood_report(db_session, seed, "Partial"))
    # Option A: 100*0.40 + 70*0.30 + Partial 50*0.30 = 76
    assert partial["score"] == 76.0 and partial["priority_level"] == "High"

    done = compute_priority(_validated_flood_report(db_session, seed, "Complete"))
    assert done["priority_level"] == "Low"
    assert done["score"] < 35
    assert "fulfilled" in done["recommendation"].lower()