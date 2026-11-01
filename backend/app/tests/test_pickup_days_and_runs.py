"""Oct 10 notes (Daniel / Disaster Unit):

1. Door to Door donors choose the days they are home (Mon / Tue / ...)
   instead of one date and time. Pickups happen within the CSWS pickup
   hours (9:00 AM to 5:00 PM by default).
2. The CSWS Disaster Unit sees every Door to Door donation still waiting
   (the pickup map) and asks DRRMO for logistics support for a pickup run:
   one day, the donations in stop order, and what is needed.
"""
from datetime import datetime, timedelta

from schemas.physical_donation_schema import MANILA, pickup_days_label, pickup_rules
from tests.test_donation_batch import LINE, _report
from tests.test_role_flows import api, ok  # noqa: F401  (fixture)


def _door(rid, days, landmark="Mandaue City Hall", lat=10.3236, lng=123.9430, **extra):
    return {
        "report_id": rid, "handover_method": "Door to Door",
        "pickup_address": "12 A. Del Rosario St., Centro, Mandaue City",
        "pickup_landmark": landmark, "pickup_lat": lat, "pickup_lng": lng,
        "pickup_days": days, "items": [LINE], **extra,
    }


def _next(weekday):
    """Next date (Philippine time) on that ISO weekday, at least tomorrow."""
    d = datetime.now(MANILA).date() + timedelta(days=1)
    while d.isoweekday() != weekday:
        d += timedelta(days=1)
    return d


def test_rules_say_9_to_5_and_name_the_days():
    rules = pickup_rules()
    assert rules["start_hour"] == 9 and rules["end_hour"] == 17
    assert rules["hours_label"] == "9:00 AM to 5:00 PM"
    assert rules["day_names"][:2] == ["Mon", "Tue"]
    assert pickup_days_label("1,3,5") == "Mon, Wed, Fri"
    assert pickup_days_label("1,2,3,4,5") == "Mon to Fri"
    assert pickup_days_label(None) is None


def test_donor_picks_pickup_days_instead_of_a_time(api):
    client, t = api
    rid = _report(client, t)
    post = lambda body: client.post("/donations/batch", headers=t["donor"], json=body)

    assert post(_door(rid, [])).status_code == 422             # at least one day
    no_days = _door(rid, None)
    no_days.pop("pickup_days")
    assert post(no_days).status_code == 422                     # days (or an old-style time) needed
    r = post(_door(rid, [6]))                                    # Saturday: not a CSWS pickup day
    assert r.status_code == 422 and "Saturday" in r.text
    assert post(_door(rid, [0])).status_code == 422

    b = ok(post(_door(rid, [5, 1, 3, 3])), 201)
    assert b["pickup_days"] == [1, 3, 5] and b["pickup_days_label"] == "Mon, Wed, Fri"
    assert b["preferred_pickup_at"] is None
    # Handover deadline: 14 days after it was submitted (no single time to count from)
    left = b["days_left"]
    assert 13 <= left <= 14

    # The donor's own records and the staff sheet show the days too
    mine = ok(client.get("/donations/mine", headers=t["donor"]))
    entry = next(e for e in mine["entries"] if e["batch_reference"] == b["batch_reference"])
    assert entry["pickup_days_label"] == "Mon, Wed, Fri"
    staff = ok(client.get(f"/donations/by-batch/{b['batch_reference']}", headers=t["csws"]))
    assert staff["pickup_days"] == [1, 3, 5]

    # Drop Off ignores pickup days
    drop = ok(post({"report_id": rid, "handover_method": "Drop Off", "pickup_days": [1], "items": [LINE]}), 201)
    assert drop["pickup_days"] == []


def _activate_everyone():
    """SQLite stores the server default "true" as text, so role lookups for
    notifications (is_active IS true) find nobody. Make it a real boolean."""
    from core import database
    from models.user_rbac_model import User
    db = database.SessionLocal()
    db.query(User).update({User.is_active: True})
    db.commit()
    db.close()


def test_disaster_unit_sees_the_pickup_map_and_requests_drrmo_support(api):
    client, t = api
    _activate_everyone()
    rid = _report(client, t)
    mon_wed = ok(client.post("/donations/batch", headers=t["donor"],
                             json=_door(rid, [1, 3], landmark="Mandaue City Hall")), 201)
    fri = ok(client.post("/donations/batch", headers=t["donor"],
                         json=_door(rid, [5], landmark="Parkmall, Mandaue City", lat=10.3270, lng=123.9330)), 201)
    a, b = mon_wed["batch_reference"], fri["batch_reference"]

    # CSWS Main Office sees the waiting pickups; donors and the Disaster Unit don't
    board = ok(client.get("/donations/pickups", headers=t["csws"]))
    row = next(p for p in board if p["batch_reference"] == a)
    assert row["pickup_days"] == [1, 3] and row["pickup_landmark"] == "Mandaue City Hall"
    assert row["pickup_lat"] == 10.3236 and row["pickup_request"] is None
    assert client.get("/donations/pickups", headers=t["donor"]).status_code == 403
    assert client.get("/donations/pickups", headers=t["unit"]).status_code == 403

    post = lambda who, body: client.post("/logistics/pickup-requests", headers=t[who], json=body)
    wed = _next(3)
    run = {"pickup_date": wed.isoformat(), "batch_references": [a], "trucks": 1, "volunteers": 2}
    # Oct 11: Main Office owns the pickup map, so it asks DRRMO for pickup runs
    assert post("unit", run).status_code == 403
    assert post("csws", {**run, "trucks": 0, "volunteers": 0}).status_code == 422
    assert post("csws", {**run, "pickup_date": _next(6).isoformat()}).status_code == 422   # Saturday
    r = post("csws", {**run, "batch_references": [a, b]})       # the Friday donor is not home on Wednesday
    assert r.status_code == 409 and "not available on Wednesday" in r.text and "Fri" in r.text
    assert post("csws", {**run, "batch_references": ["NOPE"]}).status_code == 404

    req = ok(post("csws", {**run, "batch_references": [a.lower()], "notes": "Gate is blue"}), 201)
    assert req["request_type"] == "Pickup" and req["delivery_id"] is None
    assert req["pickup_date"] == wed.isoformat()
    assert req["needs"] == "Needs 1 truck, 2 volunteers"
    assert req["stops"][0]["batch_reference"] == a and req["stops"][0]["landmark"] == "Mandaue City Hall"
    assert req["report_label"].startswith("Door to Door pickups on")
    assert "Gate is blue" in req["notes"]
    assert post("csws", run).status_code == 409                 # already in an open run

    # The map marks the stop; DRRMO sees the run next to delivery requests
    row = next(p for p in ok(client.get("/donations/pickups", headers=t["csws"])) if p["batch_reference"] == a)
    assert row["pickup_request"]["request_id"] == req["request_id"]
    drrmo = ok(client.get("/drrmo/requests", headers=t["drrmo"]))
    seen = next(x for x in drrmo if x["request_id"] == req["request_id"])
    assert seen["requested_by_role"] == "CSWS Main Office" and seen["goods"]
    assert "Door to Door stop" in seen["destination"]
    notes = ok(client.get("/notifications/", headers=t["drrmo"]))["items"]
    assert any("Door to Door pickups" in n["message"] for n in notes)

    # Main Office sees its pickup runs; DRRMO accepts; Main Office is told
    mine = ok(client.get("/logistics/requests", headers=t["csws"]))
    assert "Pickup" in [x["request_type"] for x in mine]
    ok(client.patch(f"/drrmo/requests/{req['request_id']}/accept", headers=t["drrmo"], json={}))
    assert any(n["title"] == "Logistics request accepted"
               for n in ok(client.get("/notifications/", headers=t["csws"]))["items"])

    # Main Office can cancel the run (DRRMO is told); then the stop is free again
    ok(client.post(f"/logistics/requests/{req['request_id']}/cancel", headers=t["csws"],
                   json={"reason": "Donor will drop it off instead"}))
    row = next(p for p in ok(client.get("/donations/pickups", headers=t["csws"])) if p["batch_reference"] == a)
    assert row["pickup_request"] is None
    ok(post("csws", run), 201)


def test_unit_cannot_cancel_a_delivery_request(api):
    client, t = api
    from tests.test_logistics_needs import _delivery
    did = _delivery(client, t)["delivery_id"]
    req = ok(client.post("/logistics/requests", headers=t["csws"],
                         json={"delivery_id": did, "trucks": 1}), 201)
    r = client.post(f"/logistics/requests/{req['request_id']}/cancel", headers=t["unit"],
                    json={"reason": "Not mine"})
    assert r.status_code == 403


def test_pickups_stay_in_cebu_and_far_ones_can_be_declined(api, monkeypatch):
    client, t = api
    rid = _report(client, t)
    post = lambda body: client.post("/donations/batch", headers=t["donor"], json=body)

    # A pin outside Cebu province (Manila) is refused
    r = post(_door(rid, [1], landmark="Rizal Park", lat=14.5826, lng=120.9787))
    assert r.status_code == 422 and "Cebu province" in r.text

    # Inside Cebu but outside the Door to Door service areas (Oct 23): refused.
    # The map lookup is replaced so the test stays offline.
    import api.v1.donation_routes as routes
    monkeypatch.setattr(routes, "_geocoder", lambda path, params: {
        "features": [{"properties": {"name": "Bogo City Hall", "city": "Bogo City"}}]})
    r = post(_door(rid, [1], landmark="Bogo City Hall, Bogo City, Cebu", lat=11.0517, lng=124.0055))
    assert r.status_code == 422 and "Sorry" in r.text and "Bogo City" in r.text

    # A served area can still be farther than the distance limit (5 km here)
    monkeypatch.setenv("PICKUP_MAX_KM", "5")
    near = ok(post(_door(rid, [1])), 201)                                   # Mandaue City Hall
    far = ok(post(_door(rid, [1], landmark="Marigondon, Lapu-Lapu City", lat=10.2720, lng=124.0010)), 201)
    board = {p["batch_reference"]: p for p in ok(client.get("/donations/pickups", headers=t["csws"]))}
    assert board[near["batch_reference"]]["too_far"] is False
    assert board[far["batch_reference"]]["too_far"] is True
    assert board[far["batch_reference"]]["distance_km"] > 5

    rules = ok(client.get("/donations/pickup-rules"))
    assert rules["area"]["name"] == "Cebu province" and rules["area"]["max_km"] == 5

    # Main Office declines the far one; the donor is told why
    ok(client.post(f"/donations/entries/{far['batch_reference']}/cancel", headers=t["csws"],
                   json={"reason": "Too far for a Door to Door pickup. Please drop it off instead."}))
    refs = [p["batch_reference"] for p in ok(client.get("/donations/pickups", headers=t["csws"]))]
    assert far["batch_reference"] not in refs and near["batch_reference"] in refs


def test_donor_edits_or_deletes_a_waiting_donation(api):
    client, t = api
    _activate_everyone()
    rid = _report(client, t)
    b = ok(client.post("/donations/batch", headers=t["donor"], json=_door(rid, [1, 3])), 201)
    ref = b["batch_reference"]
    staff_before = len(ok(client.get("/notifications/", headers=t["csws"]))["items"])

    # Only the donor can change it
    edit = {"handover_method": "Door to Door", "pickup_address": "12 A. Del Rosario St., Centro, Mandaue City",
            "pickup_landmark": "Mandaue City Hall", "pickup_lat": 10.3236, "pickup_lng": 123.9430,
            "pickup_days": [5],
            "items": [{"item_id": 1, "packaging": "Sack", "quantity": 9},
                      {"other_item_name": "Bottled water", "other_item_unit": "bottles",
                       "packaging": "Case", "quantity": 24}]}
    assert client.put(f"/donations/entries/{ref}", headers=t["csws"], json=edit).status_code == 403
    e = ok(client.put(f"/donations/entries/{ref}", headers=t["donor"], json=edit))
    assert e["batch_reference"] == ref and e["pickup_days"] == [5] and e["total_items"] == 2
    assert [i["quantity"] for i in e["items"]] == [9, 24]
    # Switch to Drop Off and back to one item
    e = ok(client.put(f"/donations/entries/{ref}", headers=t["donor"], json={
        "handover_method": "Drop Off", "items": [{"item_id": 1, "packaging": "Box", "quantity": 3}]}))
    assert e["handover_method"] == "Drop Off" and e["total_items"] == 1 and e["pickup_days"] == []
    assert ref not in [p["batch_reference"] for p in ok(client.get("/donations/pickups", headers=t["csws"]))]

    # A declined donation can be fixed and is waiting again
    door = ok(client.post("/donations/batch", headers=t["donor"], json=_door(rid, [1])), 201)
    ok(client.post(f"/donations/entries/{door['batch_reference']}/cancel", headers=t["csws"],
                   json={"reason": "Too far for a Door to Door pickup."}))
    fixed = ok(client.put(f"/donations/entries/{door['batch_reference']}", headers=t["donor"], json={
        "handover_method": "Drop Off", "items": [{"item_id": 1, "packaging": "Box", "quantity": 2}]}))
    assert fixed["status"] == "Pending" and fixed["days_left"] >= 13

    # Delete: gone for the donor and for staff, with its notifications; no new ones
    ok(client.delete(f"/donations/entries/{ref}", headers=t["donor"]))
    assert client.get(f"/donations/by-batch/{ref}", headers=t["csws"]).status_code == 404
    mine = ok(client.get("/donations/mine", headers=t["donor"]))
    assert ref not in [x["batch_reference"] for x in mine["entries"]]
    assert len(ok(client.get("/notifications/", headers=t["csws"]))["items"]) <= staff_before + 1

    # Received goods can no longer be changed or deleted
    got = ok(client.post("/donations/batch", headers=t["donor"], json={
        "report_id": rid, "handover_method": "Drop Off", "items": [{"item_id": 1, "packaging": "Box", "quantity": 2}]}), 201)
    ok(client.post(f"/donations/entries/{got['batch_reference']}/receive", headers=t["csws"], json={
        "items": [{"donation_id": got["items"][0]["donation_id"], "actual_quantity": 2}]}))
    assert client.delete(f"/donations/entries/{got['batch_reference']}", headers=t["donor"]).status_code == 409
    assert client.put(f"/donations/entries/{got['batch_reference']}", headers=t["donor"], json={
        "handover_method": "Drop Off", "items": [{"item_id": 1, "packaging": "Box", "quantity": 5}]}).status_code == 409


def test_deleting_the_only_stop_cancels_the_pickup_run(api):
    client, t = api
    rid = _report(client, t)
    a = ok(client.post("/donations/batch", headers=t["donor"], json=_door(rid, [3])), 201)["batch_reference"]
    req = ok(client.post("/logistics/pickup-requests", headers=t["csws"], json={
        "pickup_date": _next(3).isoformat(), "batch_references": [a], "trucks": 1}), 201)
    ok(client.delete(f"/donations/entries/{a}", headers=t["donor"]))
    run = next(r for r in ok(client.get("/logistics/requests", headers=t["csws"]))
               if r["request_id"] == req["request_id"])
    assert run["status"] == "Cancelled"
