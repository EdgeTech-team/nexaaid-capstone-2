"""CSWS Main Office <-> DRRMO delivery flow (UC-CM2 alt 3a, UC-DR1, UC-DR2,
Table 36 Logistics Support Coordination, Table 37 Delivery Tracking)."""
from datetime import timedelta

from tests.test_logistics_needs import _delivery
from tests.test_pickup_days_and_runs import _activate_everyone
from tests.test_role_flows import accept_body, api, ok  # noqa: F401  (fixture)
from tests.test_shared_logistics_notifications import _add_user, _events


def _ask(client, t, did, **needs):
    return ok(client.post("/logistics/requests", headers=t["csws"],
                          json={"delivery_id": did, "trucks": 1, **needs}), 201)


def _row(client, headers, rid):
    return next(r for r in ok(client.get("/logistics/requests", headers=headers))
                if r["request_id"] == rid)


# --- Phase 1 -----------------------------------------------------------------

def test_pending_request_blocks_csws_with_a_plain_reason(api):
    client, t = api
    did = _delivery(client, t)["delivery_id"]
    rid = _ask(client, t, did)["request_id"]
    r = client.post(f"/deliveries/{did}/advance", headers=t["csws"])
    assert r.status_code == 409
    assert f"waiting for DRRMO to accept request #{rid}" in r.json()["detail"]
    assert "cancel the DRRMO request" in r.json()["detail"]


def test_declined_request_tells_all_csws_and_lets_them_ask_again_or_send(api):
    client, t = api
    csws2 = _add_user(client, "csws2", "CSWS Main Office")
    _activate_everyone()
    did = _delivery(client, t)["delivery_id"]
    rid = _ask(client, t, did, volunteers=2)["request_id"]
    ok(client.patch(f"/drrmo/requests/{rid}/decline", headers=t["drrmo"],
                    json={"notes": "No truck available"}))

    # Table 36 alt 3a: every CSWS Main Office user hears, not only the requester.
    assert "logistics_declined" in _events(client, t["csws"])
    assert "logistics_declined" in _events(client, csws2)
    note = next(n for n in ok(client.get("/notifications/", headers=csws2))["items"]
                if n["type"] == "logistics_declined")
    assert f"delivery #{did}" in note["message"] and "No truck available" in note["message"]

    # The card shows why, and the original needs stay for "Ask DRRMO again".
    row = _row(client, t["csws"], rid)
    assert row["stage"] == "Declined" and row["reason"] == "No truck available"
    assert row["needs"] == "Needs 1 truck, 2 volunteers"

    # A declined request no longer holds the delivery: CSWS can ask again.
    assert _ask(client, t, did)["status"] == "Pending"


def test_declined_request_does_not_block_csws(api):
    client, t = api
    did = _delivery(client, t)["delivery_id"]
    rid = _ask(client, t, did)["request_id"]
    ok(client.patch(f"/drrmo/requests/{rid}/decline", headers=t["drrmo"], json={"notes": "Busy"}))
    assert ok(client.post(f"/deliveries/{did}/advance", headers=t["csws"]))["status"] == "In Transit"


def test_drrmo_hears_about_a_delivery_only_when_involved(api):
    client, t = api
    drrmo2 = _add_user(client, "drrmo2", "DRRMO Logistics Support")
    csws2 = _add_user(client, "csws2", "CSWS Main Office")
    _activate_everyone()

    # No DRRMO request: CSWS sends it, DRRMO is not told.
    alone = _delivery(client, t)["delivery_id"]
    ok(client.post(f"/deliveries/{alone}/advance", headers=t["csws"]))
    assert "delivery_status_changed" not in _events(client, t["drrmo"])
    assert "delivery_status_changed" not in _events(client, drrmo2)
    assert "delivery_status_changed" in _events(client, csws2)       # CSWS follows every step

    # Accepted by one DRRMO user: only that user hears the next steps.
    did = _delivery(client, t)["delivery_id"]
    rid = _ask(client, t, did)["request_id"]
    ok(client.patch(f"/drrmo/requests/{rid}/accept", headers=drrmo2, json=accept_body()))
    ok(client.post(f"/drrmo/requests/{rid}/picked-up", headers=drrmo2))
    ok(client.post(f"/deliveries/{did}/reschedule", headers=t["csws"],
                   json={"delivery_date": "2027-01-05T08:00:00+08:00", "reason": "Road closed"}))
    assert "delivery_status_changed" not in _events(client, t["drrmo"])  # not their job
    assert "delivery_rescheduled" not in _events(client, t["drrmo"])
    assert "delivery_rescheduled" in _events(client, drrmo2)
    assert "delivery_status_changed" in _events(client, t["csws"])
    assert "delivery_status_changed" not in _events(client, drrmo2)     # did it themselves


# --- Phase 3 -----------------------------------------------------------------

def test_only_the_drrmo_user_who_accepted_moves_the_delivery(api):
    """Table 36 / Table 37: the assigned DRRMO user (or the Administrator)
    moves a delivery DRRMO carries; CSWS and other DRRMO users are told who."""
    client, t = api
    drrmo2 = _add_user(client, "drrmo2", "DRRMO Logistics Support")
    _activate_everyone()
    did = _delivery(client, t)["delivery_id"]
    rid = _ask(client, t, did)["request_id"]
    ok(client.patch(f"/drrmo/requests/{rid}/accept", headers=t["drrmo"],
                    json=accept_body(vehicle="Truck 2")))

    r = client.post(f"/drrmo/requests/{rid}/picked-up", headers=drrmo2)
    assert r.status_code == 403 and "Only they or the Administrator" in r.json()["detail"]
    r = client.post(f"/deliveries/{did}/advance", headers=t["csws"])
    assert r.status_code == 409 and "goes with DRRMO" in r.json()["detail"]
    mine = {x["request_id"]: x["mine"] for x in ok(client.get("/drrmo/requests", headers=drrmo2))}
    assert mine[rid] is False
    assert {x["request_id"]: x["mine"]
            for x in ok(client.get("/drrmo/requests", headers=t["drrmo"]))}[rid] is True

    ok(client.post(f"/drrmo/requests/{rid}/picked-up", headers=t["drrmo"]))
    # The Administrator can step in when that DRRMO user is away.
    row = ok(client.post(f"/drrmo/requests/{rid}/delivered", headers=t["admin"]))
    assert row["delivery_status"] == "Delivered" and row["status"] == "Completed"
    assert "with Truck 2" in row["notes"]


def test_csws_still_moves_deliveries_without_drrmo(api):
    client, t = api
    did = _delivery(client, t)["delivery_id"]
    assert ok(client.post(f"/deliveries/{did}/advance", headers=t["csws"]))["status"] == "In Transit"
    assert ok(client.post(f"/deliveries/{did}/advance", headers=t["csws"]))["status"] == "Delivered"
    # DRRMO has no say in a delivery it does not carry.
    assert client.post(f"/deliveries/{did}/advance", headers=t["drrmo"]).status_code == 403


# --- Phase 6 -----------------------------------------------------------------

def _actions(client, headers):
    out = ok(client.get("/deliveries/needs-action", headers=headers))
    return {i["key"]: i["count"] for i in out["items"]}, out["all_caught_up"]


def test_needs_your_action_for_csws(api):
    client, t = api
    assert _actions(client, t["csws"]) == ({}, True)                     # All caught up
    a = _delivery(client, t)["delivery_id"]
    b = _delivery(client, t)["delivery_id"]
    assert _actions(client, t["csws"])[0] == {"packing": 2}
    rid = _ask(client, t, b)["request_id"]
    ok(client.patch(f"/drrmo/requests/{rid}/decline", headers=t["drrmo"], json={"notes": "Busy"}))
    ok(client.post(f"/deliveries/{a}/advance", headers=t["csws"]))
    ok(client.post(f"/deliveries/{a}/advance", headers=t["csws"]))
    assert _actions(client, t["csws"])[0] == {"declined": 1, "arrived": 1}  # zeros hidden


def test_needs_your_action_for_drrmo(api):
    client, t = api
    did = _delivery(client, t)["delivery_id"]
    rid = _ask(client, t, did)["request_id"]
    assert _actions(client, t["drrmo"])[0] == {"new": 1}
    ok(client.patch(f"/drrmo/requests/{rid}/accept", headers=t["drrmo"], json=accept_body()))
    assert _actions(client, t["drrmo"])[0] == {"today": 1}
    ok(client.post(f"/drrmo/requests/{rid}/picked-up", headers=t["drrmo"]))
    assert _actions(client, t["drrmo"])[0] == {"on_the_way": 1}


def test_create_delivery_with_drrmo_transport_in_one_save(api):
    from tests.test_manuscript_functions import _validated_report_with_stock
    client, t = api
    rid, d = _validated_report_with_stock(client, t)
    ok(client.post("/donations/receive", headers=t["csws"],
                   json={"donation_id": d["donation_id"], "actual_quantity": 60}))
    body = {"report_id": rid, "destination_barangay_id": 1, "delivery_date": "2026-10-01T08:00:00",
            "items": [{"item_id": 1, "quantity": 10}]}
    bad = client.post("/deliveries/", headers=t["csws"],
                      json={**body, "transport": {"trucks": 0, "volunteers": 0}})
    assert bad.status_code == 422                       # something must be needed
    did = ok(client.post("/deliveries/", headers=t["csws"],
                         json={**body, "transport": {"trucks": 1, "volunteers": 2}}), 201)["delivery_id"]
    row = next(r for r in ok(client.get("/drrmo/requests", headers=t["drrmo"]))
               if r["delivery_id"] == did)
    assert row["status"] == "Pending" and row["needs"] == "Needs 1 truck, 2 volunteers"


def test_batch_on_the_way_is_all_or_nothing(api):
    client, t = api
    a = _delivery(client, t)["delivery_id"]
    b = _delivery(client, t)["delivery_id"]
    held = _delivery(client, t)["delivery_id"]
    _ask(client, t, held)                               # waits for DRRMO
    r = client.post("/deliveries/advance-batch", headers=t["csws"], json={"delivery_ids": [a, held, b]})
    assert r.status_code == 409 and f"Delivery #{held}" in r.json()["detail"]
    assert "Nothing was changed" in r.json()["detail"]
    assert ok(client.get(f"/deliveries/{a}", headers=t["csws"]))["status"] == "Preparing"
    out = ok(client.post("/deliveries/advance-batch", headers=t["csws"], json={"delivery_ids": [a, b]}))
    assert out["moved"] == [a, b]
    assert ok(client.get(f"/deliveries/{b}", headers=t["csws"]))["status"] == "In Transit"
    assert client.post("/deliveries/advance-batch", headers=t["drrmo"],
                       json={"delivery_ids": [a]}).status_code == 403


def test_deliveries_sorted_by_report_priority(api):
    client, t = api
    _delivery(client, t)
    assert ok(client.get("/deliveries/", headers=t["csws"], params={"sort": "priority"}))


# --- Phase 7 -----------------------------------------------------------------

def test_undo_last_step_same_person_within_10_minutes(api, monkeypatch):
    import api.v1.deliveries as deliveries
    client, t = api
    did = _delivery(client, t)["delivery_id"]
    ok(client.post(f"/deliveries/{did}/advance", headers=t["csws"]))          # On the way
    assert client.post(f"/deliveries/{did}/undo", headers=t["admin"]).status_code == 403
    assert ok(client.post(f"/deliveries/{did}/undo", headers=t["csws"]))["status"] == "Preparing"
    assert client.post(f"/deliveries/{did}/undo", headers=t["csws"]).status_code == 409  # nothing left
    hist = ok(client.get(f"/deliveries/{did}/history", headers=t["csws"]))["history"]
    assert hist[-1]["action"] == "UNDO DELIVERY STEP"                          # audit-logged

    ok(client.post(f"/deliveries/{did}/advance", headers=t["csws"]))
    real = deliveries.now_utc
    monkeypatch.setattr(deliveries, "now_utc", lambda: real() + timedelta(minutes=11))
    r = client.post(f"/deliveries/{did}/undo", headers=t["csws"])
    assert r.status_code == 409 and "10 minutes" in r.json()["detail"]


def test_undo_never_after_the_barangay_confirmed(api):
    client, t = api
    did = _delivery(client, t)["delivery_id"]
    ok(client.post(f"/deliveries/{did}/advance", headers=t["csws"]))
    ok(client.post(f"/deliveries/{did}/advance", headers=t["csws"]))
    ok(client.post(f"/deliveries/{did}/confirm-receipt", headers=t["brgy"], json={}), 201)
    r = client.post(f"/deliveries/{did}/undo", headers=t["csws"])
    assert r.status_code == 409 and "confirmed receipt" in r.json()["detail"]


def test_undoing_an_arrival_reopens_drrmos_request(api):
    client, t = api
    did = _delivery(client, t)["delivery_id"]
    rid = _ask(client, t, did)["request_id"]
    ok(client.patch(f"/drrmo/requests/{rid}/accept", headers=t["drrmo"], json=accept_body()))
    ok(client.post(f"/drrmo/requests/{rid}/picked-up", headers=t["drrmo"]))
    assert ok(client.post(f"/drrmo/requests/{rid}/delivered", headers=t["drrmo"]))["status"] == "Completed"
    assert ok(client.post(f"/deliveries/{did}/undo", headers=t["drrmo"]))["status"] == "In Transit"
    assert _row(client, t["csws"], rid)["status"] == "Accepted"


def test_cancelling_a_packed_delivery_tells_the_drrmo_user_who_accepted(api):
    client, t = api
    drrmo2 = _add_user(client, "drrmo2", "DRRMO Logistics Support")
    _activate_everyone()
    did = _delivery(client, t)["delivery_id"]
    rid = _ask(client, t, did)["request_id"]
    ok(client.patch(f"/drrmo/requests/{rid}/accept", headers=t["drrmo"], json=accept_body()))
    out = ok(client.post(f"/deliveries/{did}/cancel", headers=t["csws"], json={"reason": "Road closed"}))
    assert out["status"] == "Cancelled" and out["cancelled_requests"] == [rid] and out["returned_to_stock"]
    assert "delivery_cancelled" in _events(client, t["drrmo"])
    assert "delivery_cancelled" not in _events(client, drrmo2)


def test_response_times_from_the_audit_log(api):
    client, t = api
    assert ok(client.get("/deliveries/timing/summary", headers=t["drrmo"]))["accepted"] == 0
    did = _delivery(client, t)["delivery_id"]
    rid = _ask(client, t, did)["request_id"]
    ok(client.patch(f"/drrmo/requests/{rid}/accept", headers=t["drrmo"], json=accept_body()))
    ok(client.post(f"/drrmo/requests/{rid}/picked-up", headers=t["drrmo"]))
    ok(client.post(f"/drrmo/requests/{rid}/delivered", headers=t["drrmo"]))
    out = ok(client.get("/deliveries/timing/summary", headers=t["csws"]))
    assert out["accepted"] == 1 and out["accept_minutes"] is not None
    assert out["trips"] == 1 and out["trip_minutes"] is not None
    assert client.get("/deliveries/timing/summary", headers=t["brgy"]).status_code == 403
