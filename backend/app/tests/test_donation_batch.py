"""
One QR per donation (UC-D2 step 6), CSWS lookup by that QR (UC-CM1 step 2),
per-item receiving (UC-CM1 alt 4a), Door to Door pin (alt 7c) and drop-off
details (alt 7b). Uses the same real-auth fixture as test_role_flows.
"""
from tests.test_role_flows import api, ok, PASSWORD  # noqa: F401  (fixture)


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


def test_batch_rules_and_door_to_door_pin(api):
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
    assert post(door).status_code == 422                                  # alt 7c: address needed
    assert post({**door, "pickup_address": "X", "pickup_lat": 10.3}).status_code == 422

    g = ok(post({**door, "pickup_address": "  123 Osmeña Blvd, Cebu City ",
                 "pickup_lat": 10.3157, "pickup_lng": 123.8854,
                 "pickup_landmark": "blue gate",
                 "guest_donor": {"full_name": "Guest", "contact_number": "0917"}},
                headers={}), 201)
    assert g["pickup_address"] == "123 Osmeña Blvd, Cebu City"
    assert (g["pickup_lat"], g["pickup_lng"], g["pickup_landmark"]) == (10.3157, 123.8854, "blue gate")
    staff = ok(client.get(f"/donations/by-batch/{g['batch_reference']}", headers=t["csws"]))
    assert staff["donor"] == "Guest (guest)" and staff["donor_contact"] == "0917"

    # Drop Off never keeps pickup details
    d = ok(post({**base, "pickup_address": "ignored", "pickup_lat": 1, "pickup_lng": 1}), 201)
    assert d["pickup_address"] is None and d["pickup_lat"] is None


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


def test_drop_off_info_and_location_without_key(api, monkeypatch):
    client, _ = api
    monkeypatch.setenv("DROPOFF_ADDRESS", "Test Office, Cebu City")
    monkeypatch.setenv("DROPOFF_LAT", "10.3")
    monkeypatch.setenv("DROPOFF_LNG", "123.9")
    info = ok(client.get("/donations/drop-off-info"))
    assert info["address"] == "Test Office, Cebu City" and (info["lat"], info["lng"]) == (10.3, 123.9)
    monkeypatch.delenv("DROPOFF_LNG")
    assert ok(client.get("/donations/drop-off-info"))["lat"] is None

    monkeypatch.delenv("GOOGLE_MAPS_SERVER_KEY", raising=False)
    assert client.get("/donations/location/autocomplete?q=ayala").status_code == 503
    assert client.get("/donations/location/reverse?lat=10.3&lng=123.9").status_code == 503