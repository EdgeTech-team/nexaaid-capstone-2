"""Phase 5: reminders for the CSWS <-> DRRMO delivery flow (Scope 7.5,
Table 36, Table 37). Time is frozen by passing `now` to run_reminders."""
from datetime import datetime, timedelta, timezone

from core import database
from services.delivery_reminders import run_reminders
from tests.test_csws_drrmo_flow import _ask
from tests.test_logistics_needs import _delivery
from tests.test_pickup_days_and_runs import _activate_everyone
from tests.test_role_flows import accept_body, api, ok  # noqa: F401  (fixture)
from tests.test_shared_logistics_notifications import _add_user, _events


def _run(now):
    db = database.SessionLocal()
    try:
        sent = run_reminders(db, now)
        db.commit()
        return sent
    finally:
        db.close()


def _start(client, t):
    _activate_everyone()
    return datetime.now(timezone.utc), _delivery(client, t)["delivery_id"]


def test_pending_request_reminds_drrmo_after_1h_and_csws_after_3h(api):
    client, t = api
    t0, did = _start(client, t)
    _ask(client, t, did)

    assert _run(t0 + timedelta(minutes=30))["request_waiting"] == 0
    assert _run(t0 + timedelta(minutes=61)) == {
        "request_waiting": 1, "request_waiting_csws": 0, "in_transit_long": 0,
        "pickup_overdue": 0, "not_confirmed": 0}
    assert "reminder_request_waiting" in _events(client, t["drrmo"])
    # No repeat within the window...
    assert _run(t0 + timedelta(minutes=70))["request_waiting"] == 0
    # ...CSWS hears after 3 hours, DRRMO is not told twice.
    sent = _run(t0 + timedelta(hours=3, minutes=1))
    assert sent["request_waiting_csws"] == 1 and sent["request_waiting"] == 0
    assert "reminder_request_waiting_csws" in _events(client, t["csws"])
    # After the window, DRRMO is reminded again.
    assert _run(t0 + timedelta(hours=13))["request_waiting"] == 1


def test_no_reminder_once_drrmo_answered(api):
    client, t = api
    t0, did = _start(client, t)
    rid = _ask(client, t, did)["request_id"]
    ok(client.patch(f"/drrmo/requests/{rid}/decline", headers=t["drrmo"], json={"notes": "Busy"}))
    assert not any(_run(t0 + timedelta(hours=5)).values())


def test_long_trip_reminds_csws_and_only_the_drrmo_user_carrying_it(api):
    client, t = api
    drrmo2 = _add_user(client, "drrmo2", "DRRMO Logistics Support")
    t0, did = _start(client, t)
    rid = _ask(client, t, did)["request_id"]
    ok(client.patch(f"/drrmo/requests/{rid}/accept", headers=t["drrmo"], json=accept_body()))
    ok(client.post(f"/drrmo/requests/{rid}/picked-up", headers=t["drrmo"]))

    assert _run(t0 + timedelta(hours=23))["in_transit_long"] == 0
    assert _run(t0 + timedelta(hours=25))["in_transit_long"] == 2      # CSWS + carrier
    assert "reminder_in_transit_long" in _events(client, t["drrmo"])
    assert "reminder_in_transit_long" not in _events(client, drrmo2)


def test_late_pickup_reminds_the_assigned_drrmo_user_and_csws(api):
    client, t = api
    t0, did = _start(client, t)
    rid = _ask(client, t, did)["request_id"]
    ok(client.patch(f"/drrmo/requests/{rid}/accept", headers=t["drrmo"], json=accept_body()))

    assert _run(t0 + timedelta(minutes=10))["pickup_overdue"] == 0     # a little slack
    assert _run(t0 + timedelta(minutes=45))["pickup_overdue"] == 2
    assert "reminder_pickup_overdue" in _events(client, t["csws"])
    # Picked up: no more reminders about it.
    ok(client.post(f"/drrmo/requests/{rid}/picked-up", headers=t["drrmo"]))
    assert _run(t0 + timedelta(hours=13))["pickup_overdue"] == 0


def test_arrived_but_not_received_reminds_csws_after_24h(api):
    client, t = api
    t0, did = _start(client, t)
    ok(client.post(f"/deliveries/{did}/advance", headers=t["csws"]))
    ok(client.post(f"/deliveries/{did}/advance", headers=t["csws"]))   # Delivered

    assert _run(t0 + timedelta(hours=20))["not_confirmed"] == 0
    assert _run(t0 + timedelta(hours=25))["not_confirmed"] == 1
    note = next(n for n in ok(client.get("/notifications/", headers=t["csws"]))["items"]
                if n["type"] == "reminder_not_confirmed")
    assert f"Delivery #{did}" in note["message"] and note["entity_id"] == did
    # The barangay confirms: nothing more to remind.
    ok(client.post(f"/deliveries/{did}/confirm-receipt", headers=t["brgy"], json={}), 201)
    assert _run(t0 + timedelta(hours=40))["not_confirmed"] == 0
