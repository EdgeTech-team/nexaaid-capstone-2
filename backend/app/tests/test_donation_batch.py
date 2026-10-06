"""
One QR per donation (UC-D2 step 6), CSWS lookup by that QR (UC-CM1 step 2),
per-item receiving (UC-CM1 alt 4a), Door to Door address and preferred
pickup time (alt 7c) and drop-off details (alt 7b). Uses the same real-auth
fixture as test_role_flows.
"""
from datetime import datetime, timedelta

from schemas.physical_donation_schema import MANILA
from tests.test_role_flows import api, ok, PASSWORD  # noqa: F401  (fixture)


def _pickup_slot(hour=10, weekday=None):
    """Next allowed pickup time (weekday, Philippine time), at least a day ahead.
    weekday: 1 = Monday ... 7 = Sunday; None = next Monday-Friday."""
    d = datetime.now(MANILA) + timedelta(days=1)
    while (weekday is None and d.isoweekday() > 5) or (weekday is not None and d.isoweekday() != weekday):
        d += timedelta(days=1)
    return d.replace(hour=hour, minute=0, second=0, microsecond=0)


def _report(client, t, validate=True):
    rid = ok(client.post("/reports/", headers=t["unit"], json={
        "disaster_type_id": 1, "barangay_id": 1, "estimated_quantity": 200}), 201)["report_id"]
    if validate:
        ok(client.post(f"/reports/{rid}/validate", headers=t["admin"], json={}))
    return rid


LINE = {"item_id": 1, "packaging": "Box", "quantity": 2}


def test_one_qr_for_many_items_and_per_item_receiving(api):
    client, t = api
    rid = _report(client, t)
    b = ok(client.post("/donations/batch", headers=t["donor"], json={
        "report_id": rid,
        "handover_method": "Drop Off",
        "items": [
            {"item_id": 1, "packaging": "Sack (50 kg)", "quantity": 20},
            {"other_item_name": "Bottled Water", "other_item_unit": "bottles",
             "packaging": "Box", "quantity": 48},
            {"item_id": 1, "packaging": "Pack", "quantity": 5},
        ],
    }), 201)
    ref = b["batch_reference"]
    assert b["qr_image_base64"] and b["total_items"] == 3 and b["status"] == "Pending"
    assert all(i["qr_reference"].startswith(ref + "-") for i in b["items"])
    assert "donor" not in b                      # donor details are staff-only

    # Public re-show of the QR returns only the reference + image
    qr = ok(client.get(f"/donations/batch/{ref}/qr"))
    assert qr["batch_reference"] == ref and qr["qr_image_base64"]
    assert ok(client.get(f"/donations/{b['items'][2]['donation_id']}/qr"))["batch_reference"] == ref

    # UC-CM1 step 2: the one QR opens the whole donation
    found = ok(client.get(f"/donations/by-batch/{ref.lower()}", headers=t["csws"]))
    assert [i["donation_id"] for i in found["items"]] == [i["donation_id"] for i in b["items"]]
    assert found["donor"] and found["report_id"] == rid
    by_line = ok(client.get(f"/donations/by-batch/{b['items'][1]['qr_reference']}", headers=t["csws"]))
    assert by_line["batch_reference"] == ref
    assert client.get(f"/donations/by-batch/{ref}", headers=t["donor"]).status_code == 403
    assert client.get("/donations/by-batch/DON-NOPE", headers=t["csws"]).status_code == 404

    # Each item is received on its own (UC-CM1 alt 4a: 18 of 20 accepted)
    first = b["items"][0]
    ok(client.post("/donations/receive", headers=t["csws"],
                   json={"donation_id": first["donation_id"], "actual_quantity": 18}))
    again = ok(client.get(f"/donations/by-batch/{ref}", headers=t["csws"]))
    assert again["status"] == "Partly Received"
    assert again["items"][0]["actual_quantity_received"] == 18
    assert [i["status"] for i in again["items"]] == ["Received", "Pending", "Pending"]

    mine = ok(client.get("/donations/mine", headers=t["donor"]))
    assert {d["batch_reference"] for d in mine["donations"]} == {ref}
    assert mine["summary"]["total_donations"] == 3 and mine["summary"]["total_batches"] == 1


def test_batch_is_all_or_nothing(api):
    client, t = api
    rid = _report(client, t)
    r = client.post("/donations/batch", headers=t["donor"], json={
        "report_id": rid, "handover_method": "Drop Off",
        "items": [LINE, {**LINE, "item_id": 99999}]})
    assert r.status_code == 404
    assert ok(client.get("/donations/mine", headers=t["donor"]))["summary"]["total_donations"] == 0


def test_batch_rules_and_door_to_door_pickup(api):
    client, t = api
    rid = _report(client, t)
    pending_rid = _report(client, t, validate=False)
    post = lambda body, headers=t["donor"]: client.post("/donations/batch", headers=headers, json=body)
    base = {"report_id": rid, "handover_method": "Drop Off", "items": [LINE]}

    assert post({**base, "report_id": pending_rid}).status_code == 400    # UC-D2 alt 2a
    assert post({**base, "report_id": 99999}).status_code == 404          # module alt 4a
    assert post({**base, "items": []}).status_code == 422                 # alt 7a
    assert post({**base, "items": [{**LINE, "quantity": 0}]}).status_code == 422
    assert post(base, headers={}).status_code == 400                      # no login, no guest
    door = {**base, "handover_method": "Door to Door"}
    slot = _pickup_slot()
    assert post({**door, "preferred_pickup_at": slot.isoformat()}).status_code == 422  # address needed
    assert post({**door, "pickup_address": "X"}).status_code == 422                     # time needed
    assert post({**door, "pickup_address": "X", "pickup_lat": 10.3,
                 "preferred_pickup_at": slot.isoformat()}).status_code == 422

    # Pickup time outside CSWS pickup rules
    with_addr = {**door, "pickup_address": "X"}
    assert post({**with_addr, "preferred_pickup_at": _pickup_slot(hour=19).isoformat()}).status_code == 422
    assert post({**with_addr, "preferred_pickup_at": _pickup_slot(weekday=7).isoformat()}).status_code == 422
    assert post({**with_addr, "preferred_pickup_at": (slot - timedelta(days=10)).isoformat()}).status_code == 422
    assert post({**with_addr, "preferred_pickup_at": (slot + timedelta(days=60)).isoformat()}).status_code == 422

    g = ok(post({**door, "pickup_address": "  P.J. Burgos St, Mandaue City ",
                 "pickup_lat": 10.32456, "pickup_lng": 123.94302,
                 "preferred_pickup_at": slot.isoformat(),
                 "guest_donor": {"full_name": "Guest", "contact_number": "0917 123 4567"}},
                headers={}), 201)
    assert g["pickup_address"] == "P.J. Burgos St, Mandaue City"
    assert (g["pickup_lat"], g["pickup_lng"]) == (10.32456, 123.94302)
    assert datetime.fromisoformat(g["preferred_pickup_at"]) == slot
    staff = ok(client.get(f"/donations/by-batch/{g['batch_reference']}", headers=t["csws"]))
    assert staff["donor"] == "Guest (guest)" and staff["donor_contact"] == "09171234567"
    assert staff["donor_type"] == "Guest"
    assert datetime.fromisoformat(staff["preferred_pickup_at"]) == slot

    # Drop Off never keeps pickup details
    d = ok(post({**base, "pickup_address": "ignored", "pickup_lat": 1, "pickup_lng": 1,
                 "preferred_pickup_at": slot.isoformat()}), 201)
    assert d["pickup_address"] is None and d["pickup_lat"] is None and d["preferred_pickup_at"] is None


def test_guest_phone_must_be_a_ph_mobile_number(api):
    client, t = api
    rid = _report(client, t)
    body = {"report_id": rid, "handover_method": "Drop Off", "items": [LINE],
            "guest_donor": {"full_name": "Guest", "contact_number": "12345"}}
    r = client.post("/donations/batch", json=body)
    assert r.status_code == 422 and "Philippine mobile number" in r.text
    body["guest_donor"]["contact_number"] = "+63 917-123-4567"
    ok(client.post("/donations/batch", json=body), 201)


def test_pickup_board_lists_waiting_door_to_door_donations(api):
    """Phase 1 pickup board: only Door to Door donations with goods still
    waiting, soonest preferred time first, with donor contact details."""
    client, t = api
    rid = _report(client, t)
    post = lambda body, headers=t["donor"]: client.post("/donations/batch", headers=headers, json=body)
    door = {"report_id": rid, "handover_method": "Door to Door"}

    later = ok(post({**door, "pickup_address": "Later St, Mandaue City",
                     "preferred_pickup_at": _pickup_slot(hour=15).isoformat(),
                     "items": [LINE]}), 201)
    sooner = ok(post({**door, "pickup_address": "Sooner St, Mandaue City",
                      "pickup_landmark": "Blue gate, call when outside",
                      "preferred_pickup_at": _pickup_slot(hour=9).isoformat(),
                      "items": [LINE, {"item_id": 1, "packaging": "Pack", "quantity": 5}],
                      "guest_donor": {"full_name": "Ana Guest", "contact_number": "09181234567"}},
                     headers={}), 201)
    ok(post({"report_id": rid, "handover_method": "Drop Off", "items": [LINE]}), 201)  # not a pickup
    done = ok(post({**door, "pickup_address": "Done St", "items": [LINE],
                    "preferred_pickup_at": _pickup_slot(hour=11).isoformat()}), 201)
    ok(client.post("/donations/receive", headers=t["csws"],
                   json={"donation_id": done["items"][0]["donation_id"], "actual_quantity": 2}))

    board = ok(client.get("/donations/pickups", headers=t["csws"]))
    assert [b["batch_reference"] for b in board] == [sooner["batch_reference"], later["batch_reference"]]
    first = board[0]
    assert first["pickup_address"] == "Sooner St, Mandaue City"
    assert first["pickup_notes"] == "Blue gate, call when outside"
    assert (first["donor"], first["donor_type"], first["donor_contact"]) == ("Ana Guest (guest)", "Guest", "09181234567")
    assert (first["total_items"], first["pending_items"]) == (2, 2)
    assert len(first["items_summary"]) == 2 and first["report_label"]
    assert board[1]["donor_type"] in ("Registered", "Organization")

    # Partly collected donations stay on the board until every item is in.
    ok(client.post("/donations/receive", headers=t["csws"],
                   json={"donation_id": sooner["items"][0]["donation_id"], "actual_quantity": 2}))
    again = ok(client.get("/donations/pickups", headers=t["csws"]))
    assert again[0]["status"] == "Partly Received" and again[0]["pending_items"] == 1

    # Donor addresses and phone numbers are staff-only (Data Privacy Act).
    assert client.get("/donations/pickups", headers=t["donor"]).status_code == 403
    assert client.get("/donations/pickups").status_code in (401, 403)


def test_pickup_rules_endpoint(api, monkeypatch):
    client, _ = api
    rules = ok(client.get("/donations/pickup-rules"))
    assert rules["days"] == [1, 2, 3, 4, 5] and (rules["start_hour"], rules["end_hour"]) == (8, 17)
    assert rules["label"] == "Monday to Friday, 8:00 AM to 5:00 PM"
    monkeypatch.setenv("PICKUP_DAYS", "1,2,3,4,5,6")
    monkeypatch.setenv("PICKUP_END_HOUR", "15")
    rules = ok(client.get("/donations/pickup-rules"))
    assert rules["label"] == "Monday to Saturday, 8:00 AM to 3:00 PM"


def test_single_item_endpoint_still_works(api):
    client, t = api
    rid = _report(client, t)
    d = ok(client.post("/donations/", headers=t["donor"], json={
        "report_id": rid, "item_id": 1, "packaging": "Box", "quantity": 3,
        "handover_method": "Drop Off"}))
    assert d["batch_reference"] == d["qr_reference"]
    found = ok(client.get(f"/donations/by-qr/{d['qr_reference']}", headers=t["csws"]))
    assert found["donation_id"] == d["donation_id"]
    assert ok(client.get(f"/donations/by-batch/{d['qr_reference']}", headers=t["csws"]))["total_items"] == 1


def test_drop_off_info(api, monkeypatch):
    client, _ = api
    monkeypatch.setenv("DROPOFF_ADDRESS", "Test Office, Cebu City")
    monkeypatch.setenv("DROPOFF_LAT", "10.3")
    monkeypatch.setenv("DROPOFF_LNG", "123.9")
    info = ok(client.get("/donations/drop-off-info"))
    assert info["address"] == "Test Office, Cebu City" and (info["lat"], info["lng"]) == (10.3, 123.9)
    monkeypatch.delenv("DROPOFF_LNG")
    assert ok(client.get("/donations/drop-off-info"))["lat"] is None


class _FakeResponse:
    def __init__(self, data, status_code=200):
        self._data = data
        self.status_code = status_code

    def json(self):
        return self._data


def test_location_search_and_reverse_use_openstreetmap(api, monkeypatch):
    """UC-D2 alt 7c. No real network call: the geocoder is faked."""
    import httpx
    client, _ = api
    calls = []

    def fake_request(method, url, **kwargs):
        calls.append((url, kwargs))
        if url.endswith("/reverse"):
            return _FakeResponse({"features": [{
                "geometry": {"coordinates": [123.8854, 10.3157]},
                "properties": {"name": "Cebu City Hall", "street": "Magallanes Street",
                               "district": "Santo Nino", "city": "Cebu City",
                               "state": "Central Visayas"},
            }]})
        ayala = {"name": "Ayala Center Cebu", "street": "Archbishop Reyes Avenue",
                 "district": "Lahug", "city": "Cebu City"}
        return _FakeResponse({"features": [
            {"geometry": {"coordinates": [123.9055, 10.3181]},
             "properties": {"osm_type": "W", "osm_id": 123, **ayala}},
            # same place stored again as a point: shown only once
            {"geometry": {"coordinates": [123.9056, 10.3182]},
             "properties": {"osm_type": "N", "osm_id": 456, **ayala}},
        ]})

    monkeypatch.setattr(httpx, "request", fake_request)

    s = ok(client.get("/donations/location/autocomplete?q=ayala test"))
    assert s == [{
        "place_id": "W123",
        "main": "Ayala Center Cebu",
        "secondary": "Archbishop Reyes Avenue, Lahug, Cebu City",
        "address": "Ayala Center Cebu, Archbishop Reyes Avenue, Lahug, Cebu City",
        "lat": 10.3181,
        "lng": 123.9055,
    }]
    url, kwargs = calls[0]
    assert url.endswith("/api")
    assert kwargs["params"]["bbox"] and "NexaAid" in kwargs["headers"]["User-Agent"]

    # Same search again is served from the cache, not the free public server
    before = len(calls)
    ok(client.get("/donations/location/autocomplete?q=ayala test"))
    assert len(calls) == before

    rv = ok(client.get("/donations/location/reverse?lat=10.31571&lng=123.88541"))
    assert rv["address"] == "Cebu City Hall, Magallanes Street, Santo Nino, Cebu City, Central Visayas"

    assert client.get("/donations/location/autocomplete?q=a")

    # Provider down -> clear 502 so the app falls back to typing + pin
    def boom(*args, **kwargs):
        raise httpx.ConnectError("down")

    monkeypatch.setattr(httpx, "request", boom)
    assert client.get("/donations/location/autocomplete?q=provider down")
    assert client.get("/donations/location/reverse?lat=10.1&lng=123.1")