"""
Unexpected delivery problems (api/v1/delivery_problems.py): reschedule,
truck came back, cancel (goods back to stock), cancel a DRRMO request, and
DRRMO withdrawing an accepted request. Each keeps a record and tells the
people affected.
"""
import core.database as database
from models.logistics_request_model import LogisticsRequest
from models.notification import Notification
from tests.test_delivery_trips import _deliver, _stocked, _trip
from tests.test_inventory_paths import _stock
from tests.test_role_flows import api, ok  # noqa: F401  (fixture)

LATER = "2030-01-15T09:00:00+08:00"


def _activate_all():
    """SQLite keeps is_active='true' as text; the role lookup for
    notifications needs a real boolean (Postgres is fine)."""
    from models.user_rbac_model import User
    db = database.SessionLocal()
    try:
        db.query(User).update({"is_active": True})
        db.commit()
    finally:
        db.close()


def _notes(kind):
    db = database.SessionLocal()
    try:
        return db.query(Notification).filter(Notification.type == kind).count()
    finally:
        db.close()


def _history(client, t, did):
    return [h["action"] for h in ok(client.get(f"/deliveries/{did}/history", headers=t["csws"]))["history"]]


def test_reschedule_and_who_may(api):
    client, t = api
    _activate_all()
    rid = _stocked(client, t)
    d = ok(_deliver(client, t, rid, [{"item_id": 1, "quantity": 10}]), 201)["delivery_id"]
    out = ok(client.post(f"/deliveries/{d}/reschedule", headers=t["csws"],
                         json={"delivery_date": LATER, "reason": "Rain"}))
    assert out["delivery_date"].startswith("2030-01-15")
    assert "RESCHEDULE DELIVERY" in _history(client, t, d)
    assert _notes("delivery_rescheduled") == 1                    # the barangay rep
    assert client.post(f"/deliveries/{d}/reschedule", headers=t["brgy"],
                       json={"delivery_date": LATER}).status_code == 403
    past = client.post(f"/deliveries/{d}/reschedule", headers=t["csws"],
                       json={"delivery_date": "2020-01-01T09:00:00+08:00"})
    assert past.status_code == 422


def test_truck_came_back_then_cancel_returns_stock(api):
    client, t = api
    _activate_all()
    rid = _stocked(client, t, qty=100)
    d = ok(_deliver(client, t, rid, [{"item_id": 1, "quantity": 40}]), 201)["delivery_id"]
    assert _stock(1, rid) == 60
    ok(client.post("/logistics/requests", headers=t["csws"], json={"delivery_id": d, "trucks": 1, "drivers": 1, "volunteers": 0}), 201)

    # Not on the road yet: nothing to bring back.
    assert client.post(f"/deliveries/{d}/return-to-office", headers=t["csws"],
                       json={"reason": "Truck broke down"}).status_code == 409
    ok(client.post(f"/deliveries/{d}/advance", headers=t["csws"]))
    # On the road: cannot cancel until it is back.
    r = client.post(f"/deliveries/{d}/cancel", headers=t["csws"], json={"reason": "Road closed"})
    assert r.status_code == 409 and "Truck came back" in r.json()["detail"]

    ok(client.post(f"/deliveries/{d}/return-to-office", headers=t["csws"],
                   json={"reason": "Truck broke down"}))
    assert ok(client.get(f"/deliveries/{d}", headers=t["csws"]))["status"] == "Preparing"
    assert _stock(1, rid) == 60                                   # still loaded for it
    assert _notes("delivery_returned") >= 1

    assert client.post(f"/deliveries/{d}/cancel", headers=t["csws"], json={"reason": "x"}).status_code == 422
    out = ok(client.post(f"/deliveries/{d}/cancel", headers=t["csws"],
                         json={"reason": "Road to the barangay is closed"}))
    assert out["status"] == "Cancelled" and out["returned_to_stock"] == [{"item_id": 1, "quantity": 40}]
    assert _stock(1, rid) == 100                                  # goods back in stock
    row = ok(client.get(f"/deliveries/{d}", headers=t["csws"]))
    assert row["cancel_reason"] == "Road to the barangay is closed" and row["cancelled_at"]
    db = database.SessionLocal()
    try:   # the open DRRMO request was cancelled with it
        assert db.query(LogisticsRequest).one().status == "Cancelled"
    finally:
        db.close()
    assert _notes("delivery_cancelled") >= 1

    # A cancelled delivery is finished: no moving, no changing, no transport.
    assert client.post(f"/deliveries/{d}/advance", headers=t["csws"]).status_code == 409
    assert client.post(f"/deliveries/{d}/reschedule", headers=t["csws"],
                       json={"delivery_date": LATER}).status_code == 409
    assert client.post("/logistics/requests", headers=t["csws"], json={"delivery_id": d, "trucks": 1, "drivers": 1, "volunteers": 0}).status_code == 409
    counts = ok(client.get("/deliveries/counts", headers=t["csws"]))
    assert counts["Cancelled"] == 1
    assert [x["delivery_id"] for x in ok(client.get("/deliveries/?status=Cancelled", headers=t["csws"]))] == [d]


def test_nothing_changes_after_it_arrived(api):
    client, t = api
    rid = _stocked(client, t)
    d = ok(_deliver(client, t, rid, [{"item_id": 1, "quantity": 5}]), 201)["delivery_id"]
    ok(client.post(f"/deliveries/{d}/advance", headers=t["csws"]))
    ok(client.post(f"/deliveries/{d}/advance", headers=t["csws"]))
    for path, body in (("reschedule", {"delivery_date": LATER}), ("cancel", {"reason": "late"}),
                       ("return-to-office", {"reason": "late"})):
        assert client.post(f"/deliveries/{d}/{path}", headers=t["csws"], json=body).status_code == 409


def test_trip_reschedule_return_and_cancel_one_stop(api):
    client, t = api
    a, b = _stocked(client, t), _stocked(client, t, barangay_id=2)
    trip = ok(_trip(client, t, [
        {"report_id": a, "items": [{"item_id": 1, "quantity": 10}]},
        {"report_id": b, "items": [{"item_id": 1, "quantity": 10}]},
    ]), 201)
    tid = trip["trip_id"]
    out = ok(client.post(f"/trips/{tid}/reschedule", headers=t["csws"], json={"delivery_date": LATER}))
    assert len(out["rescheduled_deliveries"]) == 2
    assert ok(client.get(f"/trips/{tid}", headers=t["csws"]))["trip_date"].startswith("2030-01-15")

    ok(client.post(f"/trips/{tid}/start", headers=t["csws"]))
    ok(client.post(f"/trips/{tid}/stops/1/arrived", headers=t["csws"]))      # stop A done
    back = ok(client.post(f"/trips/{tid}/return-to-office", headers=t["csws"],
                          json={"reason": "Flat tire"}))
    assert len(back["returned_deliveries"]) == 1                             # only stop B
    view = ok(client.get(f"/trips/{tid}", headers=t["csws"]))
    assert [s["status"] for s in view["stops"]] == ["Delivered", "Preparing"]

    stop_b = view["stops"][1]["deliveries"][0]["delivery_id"]
    ok(client.post(f"/deliveries/{stop_b}/cancel", headers=t["csws"], json={"reason": "Barangay not ready"}))
    assert _stock(1, b) == 100
    view = ok(client.get(f"/trips/{tid}", headers=t["csws"]))
    assert view["stops"][1]["status"] == "Cancelled" and view["status"] == "Delivered"
    ok(client.post(f"/trips/{tid}/confirm-receipt", headers=t["brgy"], json={}))
    assert ok(client.get(f"/trips/{tid}", headers=t["csws"]))["status"] == "Completed"


def test_cancel_and_withdraw_logistics_requests(api):
    client, t = api
    _activate_all()
    rid = _stocked(client, t)
    d = ok(_deliver(client, t, rid, [{"item_id": 1, "quantity": 5}]), 201)["delivery_id"]
    req = ok(client.post("/logistics/requests", headers=t["csws"], json={"delivery_id": d, "trucks": 1, "drivers": 1, "volunteers": 0}), 201)["request_id"]

    # CSWS cancels it: DRRMO is told; a new request is then allowed.
    assert client.post(f"/logistics/requests/{req}/cancel", headers=t["drrmo"],
                       json={"reason": "found a truck"}).status_code == 403
    ok(client.post(f"/logistics/requests/{req}/cancel", headers=t["csws"], json={"reason": "Found a city truck"}))
    assert _notes("logistics_cancelled") >= 1
    assert client.post(f"/logistics/requests/{req}/cancel", headers=t["csws"],
                       json={"reason": "again"}).status_code == 409
    req2 = ok(client.post("/logistics/requests", headers=t["csws"], json={"delivery_id": d, "trucks": 1, "drivers": 1, "volunteers": 0}), 201)["request_id"]

    # DRRMO can only withdraw what it accepted.
    assert client.post(f"/drrmo/requests/{req2}/withdraw", headers=t["drrmo"],
                       json={"reason": "Truck sent elsewhere"}).status_code == 409
    ok(client.patch(f"/drrmo/requests/{req2}/accept", headers=t["drrmo"], json={}))
    ok(client.post(f"/drrmo/requests/{req2}/withdraw", headers=t["drrmo"],
                   json={"reason": "Truck sent to a fire emergency"}))
    rows = ok(client.get("/logistics/requests", headers=t["csws"]))
    mine = next(r for r in rows if r["request_id"] == req2)
    assert mine["status"] == "Declined" and "fire emergency" in mine["notes"]
    assert _notes("logistics_withdrawn") == 1
    # CSWS can ask again.
    ok(client.post("/logistics/requests", headers=t["csws"], json={"delivery_id": d, "trucks": 1, "drivers": 1, "volunteers": 0}), 201)