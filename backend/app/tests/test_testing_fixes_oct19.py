"""Oct 19 testing fixes.

4.1: "sack" is packaging, not a quantity unit.
7.4: CSWS Main Office plans the date; since Nov 2026 DRRMO confirms the
     time when accepting (UC-DR1 step 5, Table 36 alt 4a).
7.5: DRRMO cannot mark support completed before the scheduled date or
     before the goods left (8.1); since Nov 2026 it completes by itself when
     the goods arrive (Table 36).
"""
from datetime import date, datetime, timedelta, timezone

from api.v1.drrmo_router import completion_blocker
from models.delivery import Delivery
from models.logistics_request_model import LogisticsRequest
from tests.test_delivery_allocation import _give
from tests.test_donation_batch import _report
from tests.test_pickup_days_and_runs import _activate_everyone
from tests.test_role_flows import accept_body, api, ok  # noqa: F401  (fixture)
from tests.test_runthrough_gaps import _deliver

PAST = "2026-01-05T08:00:00"


def _request(client, t, did):
    req = ok(client.post("/logistics/requests", headers=t["csws"],
                         json={"delivery_id": did, "trucks": 1}), 201)
    ok(client.patch(f"/drrmo/requests/{req['request_id']}/accept", headers=t["drrmo"], json=accept_body()))
    return req["request_id"]


def _row(client, t, rid):
    return next(r for r in ok(client.get("/drrmo/requests", headers=t["drrmo"]))
                if r["request_id"] == rid)


def _complete(client, t, rid):
    return client.patch(f"/drrmo/requests/{rid}/complete", headers=t["drrmo"],
                        json={"summary": "Delivered by truck 1"})


def test_7_5_support_completes_when_the_goods_arrive(api):
    """Nov 2026 (Table 36): DRRMO's support ends when the goods arrive, so
    marking the delivery Delivered completes the request by itself. Before
    that it cannot be completed by hand; the barangay's receipt is its own
    step afterwards."""
    client, t = api
    _activate_everyone()
    rid = _report(client, t)
    _give(client, t, rid, 5)
    did = _deliver(client, t, rid, when=PAST)
    req = _request(client, t, did)

    # Still Preparing: DRRMO has not picked it up (8.1).
    row = _row(client, t, req)
    assert row["can_complete"] is False and "In Transit" in row["complete_blocker"]
    r = _complete(client, t, req)
    assert r.status_code == 409 and "In Transit" in r.json()["detail"]

    # In Transit (DRRMO picked it up, advisor Oct 24): not done yet.
    ok(client.post(f"/drrmo/requests/{req}/picked-up", headers=t["drrmo"]))
    r = _complete(client, t, req)
    assert r.status_code == 409 and "Mark it Delivered" in r.json()["detail"]

    # Delivered: completed with a summary of goods, destination and time.
    row = ok(client.post(f"/drrmo/requests/{req}/delivered", headers=t["drrmo"]))
    assert row["status"] == "Completed" and row["stage"] == "Completed"
    assert "Goods arrived" in row["notes"] and "Destination:" in row["notes"]
    assert _complete(client, t, req).status_code == 400          # already completed

    # The barangay still confirms receipt on its own (UC-B1).
    ok(client.post(f"/deliveries/{did}/confirm-receipt", headers=t["brgy"], json={}), 201)
    assert _row(client, t, req)["status"] == "Completed"


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


def test_7_4_main_office_plans_drrmo_confirms_the_time(api):
    """Nov 2026 (UC-DR1 step 5, Table 36 alt 4a): Main Office's delivery date
    is the plan DRRMO is asked for; DRRMO's accept sets the time, and the
    delivery follows it. Later Main Office reschedules still reach DRRMO."""
    client, t = api
    _activate_everyone()
    rid = _report(client, t)
    _give(client, t, rid, 5)
    did = _deliver(client, t, rid)
    req = ok(client.post("/logistics/requests", headers=t["csws"],
                         json={"delivery_id": did, "trucks": 1}), 201)["request_id"]
    row = _row(client, t, req)
    assert row["scheduled_by"] == "CSWS Main Office"
    assert row["scheduled_date"].startswith("2026-10-20")

    # Nov 4 (team): once asked, the delivery is DRRMO's; Main Office can no
    # longer move it while DRRMO decides.
    later = (datetime.now(timezone.utc) + timedelta(days=10)).replace(microsecond=0)
    assert client.post(f"/deliveries/{did}/reschedule", headers=t["csws"],
                       json={"delivery_date": later.isoformat(), "reason": "Road closed"}
                       ).status_code == 409

    # DRRMO accepts for a day earlier: that is now the time everywhere.
    sooner = later - timedelta(days=1)
    ok(client.patch(f"/drrmo/requests/{req}/accept", headers=t["drrmo"],
                    json={"scheduled_date": sooner.isoformat()}))
    row = _row(client, t, req)
    assert row["scheduled_by"] == "DRRMO" and row["scheduled_date"][:10] == sooner.date().isoformat()
    assert ok(client.get(f"/deliveries/{did}", headers=t["csws"]))["delivery_date"][:10] == \
        sooner.date().isoformat()


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