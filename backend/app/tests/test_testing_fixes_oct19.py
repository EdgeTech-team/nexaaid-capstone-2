"""Oct 19 testing fixes.

4.1: "sack" is packaging, not a quantity unit.
7.4: CSWS Main Office schedules DRRMO support (the delivery date).
7.5: DRRMO cannot mark support completed before the scheduled date, before
     Main Office marks the delivery In Transit (8.1), or before the barangay
     representative confirms receipt (8.2).
"""
from datetime import date, datetime, timedelta, timezone

from api.v1.drrmo_router import completion_blocker
from models.delivery import Delivery
from models.logistics_request_model import LogisticsRequest
from tests.test_delivery_allocation import _give
from tests.test_donation_batch import _report
from tests.test_pickup_days_and_runs import _activate_everyone
from tests.test_role_flows import api, ok  # noqa: F401  (fixture)
from tests.test_runthrough_gaps import _deliver

PAST = "2026-01-05T08:00:00"


def _request(client, t, did):
    req = ok(client.post("/logistics/requests", headers=t["csws"],
                         json={"delivery_id": did, "trucks": 1}), 201)
    ok(client.patch(f"/drrmo/requests/{req['request_id']}/accept", headers=t["drrmo"], json={}))
    return req["request_id"]


def _row(client, t, rid):
    return next(r for r in ok(client.get("/drrmo/requests", headers=t["drrmo"]))
                if r["request_id"] == rid)


def _complete(client, t, rid):
    return client.patch(f"/drrmo/requests/{rid}/complete", headers=t["drrmo"],
                        json={"summary": "Delivered by truck 1"})


def test_7_5_drrmo_completes_only_after_in_transit_and_barangay_receipt(api):
    client, t = api
    _activate_everyone()
    rid = _report(client, t)
    _give(client, t, rid, 5)
    did = _deliver(client, t, rid, when=PAST)
    req = _request(client, t, did)

    # Still Preparing: Main Office has not sent it out (8.1).
    row = _row(client, t, req)
    assert row["can_complete"] is False and "In Transit" in row["complete_blocker"]
    r = _complete(client, t, req)
    assert r.status_code == 409 and "In Transit" in r.json()["detail"]

    # In Transit (DRRMO picked it up, advisor Oct 24), then Delivered:
    # still waiting for the barangay (8.2).
    for step in (f"/drrmo/requests/{req}/picked-up", f"/deliveries/{did}/advance"):
        ok(client.post(step, headers=t["drrmo" if "drrmo" in step else "csws"]))
        r = _complete(client, t, req)
        assert r.status_code == 409 and "confirm receipt" in r.json()["detail"]

    # The barangay confirms receipt: now DRRMO can complete.
    ok(client.post(f"/deliveries/{did}/confirm-receipt", headers=t["brgy"], json={}), 201)
    row = _row(client, t, req)
    assert row["can_complete"] is True and row["complete_blocker"] is None
    assert row["stage"] == "In Transit"   # does not jump back to Accepted
    assert ok(_complete(client, t, req))["status"] == "Completed"


def test_7_5_not_before_the_scheduled_date():
    """The date check alone, without the API (the app's dates are real days)."""
    tomorrow = datetime.now(timezone.utc) + timedelta(days=1)
    d = Delivery(delivery_id=1, status="Confirmed", delivery_date=tomorrow)
    req = LogisticsRequest(request_id=1, request_type="Delivery", delivery_id=1, status="Accepted")
    assert "Wait for the scheduled date" in completion_blocker(req, d)
    d.delivery_date = datetime.now(timezone.utc) - timedelta(days=1)
    assert completion_blocker(req, d) is None

    # Pickup runs: only the pickup day applies (no barangay receipt).
    pickup = LogisticsRequest(request_id=2, request_type="Pickup", status="Accepted",
                              pickup_date=date.today() + timedelta(days=2))
    assert "Wait for the scheduled date" in completion_blocker(pickup, None)
    pickup.pickup_date = date(2026, 1, 1)
    assert completion_blocker(pickup, None) is None


def test_7_4_main_office_date_is_the_drrmo_schedule(api):
    client, t = api
    _activate_everyone()
    rid = _report(client, t)
    _give(client, t, rid, 5)
    did = _deliver(client, t, rid)
    req = _request(client, t, did)
    row = _row(client, t, req)
    assert row["scheduled_by"] == "CSWS Main Office"
    assert row["scheduled_date"].startswith("2026-10-20")

    # Main Office moves the delivery: DRRMO sees the new date.
    later = (datetime.now(timezone.utc) + timedelta(days=10)).replace(microsecond=0)
    ok(client.post(f"/deliveries/{did}/reschedule", headers=t["csws"],
                   json={"delivery_date": later.isoformat(), "reason": "Road closed"}))
    assert _row(client, t, req)["scheduled_date"][:10] == later.date().isoformat()
    # DRRMO has no way to set a date.
    assert "scheduled_date" not in client.app.openapi()["components"]["schemas"][
        "AcceptLogisticsRequest"]["properties"]


def test_4_1_sack_is_not_a_quantity_unit(api):
    client, t = api
    _activate_everyone()
    rid = _report(client, t)
    line = {"other_item_name": "Corn grits", "packaging": "Sack (25 kg)", "quantity": 2}
    body = {"report_id": rid, "handover_method": "Drop Off",
    "guest_donor": {"full_name": "Juan Dela Cruz", "contact_number": "09171234567", "consent": True}}

    r = client.post("/donations/batch", json={**body, "items": [{**line, "other_item_unit": "sacks"}]})
    assert r.status_code == 422 and "packaging" in r.text
    r = client.post("/donations/batch", json={**body, "items": [{**line, "other_item_unit": "KG"}]})
    assert r.status_code == 201, r.text
    assert r.json()["items"][0]["unit"] == "kg"