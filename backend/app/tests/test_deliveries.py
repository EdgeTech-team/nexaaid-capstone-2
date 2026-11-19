"""
Tests for Module 3.10 — Delivery Tracking & Receipt Confirmation.

Extends the existing seed fixture's reporter/admin/disaster_type/
barangay/sitio with an Item row (for delivery_items) and a validated
report (needed before any delivery/fulfillment logic can run).

J1 / NF-009 and J2 / NF-015: confirming receipt needs the barangay's counts,
the handover code shown to CSWS staff and the rep's signature. The
Administrator cannot get a code, so the confirm tests run on the real-auth
`api` fixture with the Barangay Receiving Representative confirming.
"""
import pytest

import core.database as database
from models.item_model import Item
from models.inventory_model import Inventory
from models.user_rbac_model import User
from tests.receipt_helpers import ANY_COUNTS, full_counts
from tests.test_inventory_paths import _donate, _receive
from tests.test_role_flows import ACCOUNTS, api, ok  # noqa: F401  (fixture)


@pytest.fixture()
def validated_report_with_item(db_session, seed, admin_client, reporter_client):
    item = Item(item_id=1, item_name="Rice sack (25kg)", category="Food", unit_of_measure="sack")
    db_session.add(item)
    db_session.commit()

    create_resp = reporter_client.post(
        "/reports/",
        json={
            "disaster_type_id": seed["disaster_type_id"],
            "barangay_id": seed["barangay_id"],
            "description": "Flood relief needed.",
            # Oct 2026 (option C): priority comes from families + disaster
            # type x what is still missing; quantity is no longer scored.
            "affected_families": 60,
            "estimated_quantity": 100,
            "source": "web",
        },
    )
    report_id = create_resp.json()["report_id"]

    validate_resp = admin_client.post(f"/reports/{report_id}/validate", json={})
    assert validate_resp.status_code == 200

    # Deliveries now draw from the report's inventory, so stock it first.
    db_session.add(Inventory(item_id=item.item_id, report_id=report_id, quantity=1000))
    db_session.commit()

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


# --------------------------------------------- confirming receipt (real auth)
def _rep_id():
    db = database.SessionLocal()
    try:
        return db.query(User).filter(User.email == ACCOUNTS["brgy"][0]).one().user_id
    finally:
        db.close()


def _report_needing_100(client, t):
    """A validated report for 60 families needing 100 kg of rice, 100 kg in stock."""
    rid = ok(client.post("/reports/", headers=t["unit"], json={
        "disaster_type_id": 1, "barangay_id": 1, "description": "Flood relief needed.",
        "affected_families": 60, "estimated_quantity": 100}), 201)["report_id"]
    ok(client.post(f"/reports/{rid}/validate", headers=t["admin"], json={}))
    _receive(client, t, _donate(client, t, rid, 1, 100), 100)
    return rid


def _delivery(client, t, rid, quantity):
    return ok(client.post("/deliveries/", headers=t["csws"], json={
        "report_id": rid, "destination_barangay_id": 1,
        "delivery_date": "2026-09-10T08:00:00Z",
        "items": [{"item_id": 1, "quantity": quantity}]}), 201)["delivery_id"]


def _arrived(client, t, rid, quantity):
    did = _delivery(client, t, rid, quantity)
    ok(client.post(f"/deliveries/{did}/advance", headers=t["csws"]))   # In Transit
    ok(client.post(f"/deliveries/{did}/advance", headers=t["csws"]))   # Delivered
    return did


def _confirm(client, t, did, remarks=None):
    return client.post(f"/deliveries/{did}/confirm-receipt", headers=t["brgy"],
                       json=full_counts(client, did, t["brgy"], remarks=remarks))


def test_cannot_confirm_receipt_before_delivered(api):
    client, t = api
    did = _delivery(client, t, _report_needing_100(client, t), 50)
    # Still 'Preparing' — confirming now should be rejected
    resp = client.post(f"/deliveries/{did}/confirm-receipt", headers=t["brgy"], json=ANY_COUNTS)
    assert resp.status_code == 409


def test_confirm_receipt_recalculates_fulfillment(api):
    client, t = api
    did = _arrived(client, t, _report_needing_100(client, t), 50)

    resp = _confirm(client, t, did, remarks="All good")
    assert resp.status_code == 201, resp.text
    body = resp.json()

    assert body["delivery"]["status"] == "Confirmed"
    assert body["fulfillment"]["total_items_delivered"] == 50
    assert body["fulfillment"]["total_items_needed"] == 100
    assert float(body["fulfillment"]["fulfillment_percentage"]) == 50.00
    assert body["fulfillment"]["verification_status"] == "Partial"
    assert body["fulfillment"]["verified_by_user_id"] == _rep_id()


def test_full_delivery_marks_fulfillment_complete(api):
    client, t = api
    did = _arrived(client, t, _report_needing_100(client, t), 100)
    resp = _confirm(client, t, did)

    assert resp.json()["fulfillment"]["verification_status"] == "Complete"
    assert float(resp.json()["fulfillment"]["fulfillment_percentage"]) == 100.00


def test_priority_follows_fulfillment(api):
    """Testing, Module 3: the priority was set once at validation and never
    changed. It must be recomputed when a delivery changes the fulfillment."""
    client, t = api
    report_id = _report_needing_100(client, t)
    before = ok(client.get(f"/reports/{report_id}", headers=t["admin"]))
    assert before["priority_level"] == "High"          # nothing delivered yet

    # Half delivered: still needs help.
    ok(_confirm(client, t, _arrived(client, t, report_id, 50)), 201)
    mid = ok(client.get(f"/reports/{report_id}", headers=t["admin"]))
    assert mid["fulfillment_status"] == "Partial"
    assert mid["priority_level"] in ("High", "Medium")

    # The rest delivered: fully fulfilled, so the priority drops to Low.
    ok(_confirm(client, t, _arrived(client, t, report_id, 50)), 201)
    after = ok(client.get(f"/reports/{report_id}", headers=t["admin"]))
    assert after["fulfillment_status"] == "Complete"
    assert after["priority_level"] == "Low"
    assert float(after["ai_priority_score"]) < 35
