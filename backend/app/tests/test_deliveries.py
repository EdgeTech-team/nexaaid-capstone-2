"""
Tests for Module 3.10 — Delivery Tracking & Receipt Confirmation.

Extends the existing seed fixture's reporter/admin/disaster_type/
barangay/sitio with an Item row (for delivery_items) and a validated
report (needed before any delivery/fulfillment logic can run).
"""
import pytest
from models.delivery import Item


@pytest.fixture()
def validated_report_with_item(db_session, seed, admin_client, reporter_client):
    item = Item(item_id=1, name="Rice sack (25kg)")
    db_session.add(item)
    db_session.commit()

    create_resp = reporter_client.post(
        "/reports/",
        json={
            "disaster_type_id": seed["disaster_type_id"],
            "barangay_id": seed["barangay_id"],
            "description": "Flood relief needed.",
            "estimated_quantity": 100,
            "source": "web",
        },
    )
    report_id = create_resp.json()["report_id"]

    validate_resp = admin_client.post(f"/reports/{report_id}/validate", json={})
    assert validate_resp.status_code == 200

    return {"report_id": report_id, "item_id": item.item_id}


def _create_delivery(admin_client, seed, validated_report_with_item, quantity=50):
    resp = admin_client.post(
        "/deliveries/",
        json={
            "report_id": validated_report_with_item["report_id"],
            "destination_barangay_id": seed["barangay_id"],
            "delivery_date": "2026-09-10T08:00:00Z",
            "items": [
                {"item_id": validated_report_with_item["item_id"], "quantity": quantity}
            ],
        },
    )
    return resp


def test_create_delivery_starts_at_preparing(admin_client, seed, validated_report_with_item):
    resp = _create_delivery(admin_client, seed, validated_report_with_item)
    assert resp.status_code == 201
    body = resp.json()
    assert body["status"] == "Preparing"
    assert len(body["items"]) == 1


def test_cannot_skip_status_stages(admin_client, seed, validated_report_with_item):
    delivery_id = _create_delivery(admin_client, seed, validated_report_with_item).json()["delivery_id"]

    # Preparing -> In Transit: fine
    resp = admin_client.post(f"/deliveries/{delivery_id}/advance")
    assert resp.status_code == 200
    assert resp.json()["status"] == "In Transit"

    # In Transit -> Delivered: fine
    resp = admin_client.post(f"/deliveries/{delivery_id}/advance")
    assert resp.status_code == 200
    assert resp.json()["status"] == "Delivered"

    # Delivered -> next: blocked (must go through confirm-receipt instead)
    resp = admin_client.post(f"/deliveries/{delivery_id}/advance")
    assert resp.status_code == 409


def test_cannot_confirm_receipt_before_delivered(admin_client, seed, validated_report_with_item):
    delivery_id = _create_delivery(admin_client, seed, validated_report_with_item).json()["delivery_id"]
    # Still 'Preparing' — confirming now should be rejected
    resp = admin_client.post(f"/deliveries/{delivery_id}/confirm-receipt", json={})
    assert resp.status_code == 409


def test_confirm_receipt_recalculates_fulfillment(admin_client, seed, validated_report_with_item):
    delivery_id = _create_delivery(
        admin_client, seed, validated_report_with_item, quantity=50
    ).json()["delivery_id"]

    admin_client.post(f"/deliveries/{delivery_id}/advance")  # -> In Transit
    admin_client.post(f"/deliveries/{delivery_id}/advance")  # -> Delivered

    resp = admin_client.post(f"/deliveries/{delivery_id}/confirm-receipt", json={"remarks": "All good"})
    print(resp.json())
    assert resp.status_code == 201
    body = resp.json()

    assert body["delivery"]["status"] == "Confirmed"
    assert body["fulfillment"]["total_items_delivered"] == 50
    assert body["fulfillment"]["total_items_needed"] == 100
    assert float(body["fulfillment"]["fulfillment_percentage"]) == 50.00
    assert body["fulfillment"]["verification_status"] == "Partial"
    assert body["fulfillment"]["verified_by_user_id"] == seed["admin_id"]


def test_full_delivery_marks_fulfillment_complete(admin_client, seed, validated_report_with_item):
    delivery_id = _create_delivery(
        admin_client, seed, validated_report_with_item, quantity=100
    ).json()["delivery_id"]

    admin_client.post(f"/deliveries/{delivery_id}/advance")
    admin_client.post(f"/deliveries/{delivery_id}/advance")
    resp = admin_client.post(f"/deliveries/{delivery_id}/confirm-receipt", json={})

    assert resp.json()["fulfillment"]["verification_status"] == "Complete"
    assert float(resp.json()["fulfillment"]["fulfillment_percentage"]) == 100.00