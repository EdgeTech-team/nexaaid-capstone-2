"""Testing (Oct 27): CSWS deletes cancelled or confirmed deliveries from the
list. A soft delete: the lists and counts hide it, the record stays."""
from core import database
from models.delivery import Delivery
from tests.test_logistics_needs import _delivery
from tests.test_role_flows import api, ok  # noqa: F401  (fixture)


def _ids(client, headers):
    return {d["delivery_id"] for d in ok(client.get("/deliveries/", headers=headers))}


def test_only_cancelled_or_confirmed_deliveries_can_be_deleted(api):
    client, t = api
    did = _delivery(client, t)["delivery_id"]

    # Still Active: refused, and only CSWS / Admin may delete.
    r = client.delete(f"/deliveries/{did}", headers=t["csws"])
    assert r.status_code == 409 and "Only cancelled or confirmed" in r.json()["detail"]
    assert client.delete(f"/deliveries/{did}", headers=t["drrmo"]).status_code == 403

    # Confirmed by the barangay: deleted from the list, kept in the database.
    ok(client.post(f"/deliveries/{did}/advance", headers=t["csws"]))
    ok(client.post(f"/deliveries/{did}/advance", headers=t["csws"]))
    ok(client.post(f"/deliveries/{did}/confirm-receipt", headers=t["brgy"], json={}), 201)
    before = ok(client.get("/deliveries/counts", headers=t["csws"]))
    assert client.delete(f"/deliveries/{did}", headers=t["csws"]).status_code == 204
    assert did not in _ids(client, t["csws"])
    assert client.get(f"/deliveries/{did}", headers=t["csws"]).status_code == 404
    after = ok(client.get("/deliveries/counts", headers=t["csws"]))
    assert after != before
    assert client.delete(f"/deliveries/{did}", headers=t["csws"]).status_code == 404

    db = database.SessionLocal()
    try:
        row = db.get(Delivery, did)
        assert row is not None and row.status == "Confirmed" and row.deleted_at is not None
    finally:
        db.close()


def test_a_cancelled_delivery_can_be_deleted(api):
    client, t = api
    did = _delivery(client, t)["delivery_id"]
    ok(client.post(f"/deliveries/{did}/cancel", headers=t["csws"], json={"reason": "Prepared by mistake"}))
    assert client.delete(f"/deliveries/{did}", headers=t["csws"]).status_code == 204
    assert did not in _ids(client, t["csws"])
