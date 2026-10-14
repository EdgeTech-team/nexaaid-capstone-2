"""I4: CSWS picks how many trucks, volunteers and pushcarts. DRRMO just accepts.
Appendix H 7.1 (Oct 10 notes): no driver count; each need can be None."""
from tests.test_manuscript_functions import _validated_report_with_stock
from tests.test_role_flows import api, ok  # noqa: F401  (fixture)


def _delivery(client, t):
    rid, d = _validated_report_with_stock(client, t)
    ok(client.post("/donations/receive", headers=t["csws"],
                   json={"donation_id": d["donation_id"], "actual_quantity": 60}))
    return ok(client.post("/deliveries/", headers=t["csws"], json={
        "report_id": rid, "destination_barangay_id": 1, "delivery_date": "2026-10-01T08:00:00",
        "items": [{"item_id": 1, "quantity": 30}]}), 201)


def test_csws_picks_what_is_needed_and_drrmo_just_accepts(api):
    client, t = api
    did = _delivery(client, t)["delivery_id"]
    post = lambda who, body: client.post("/logistics/requests", headers=t[who], json=body)

    assert post("csws", {"delivery_id": did}).status_code == 422                     # something is needed
    assert post("csws", {"delivery_id": did, "trucks": 0, "volunteers": 0, "pushcarts": 0}).status_code == 422
    assert post("csws", {"delivery_id": did, "trucks": 99, "volunteers": 0}).status_code == 422

    body = {"delivery_id": did, "trucks": 2, "volunteers": 3, "pushcarts": 1}
    assert post("drrmo", body).status_code == 403                                     # only CSWS
    req = ok(post("csws", body), 201)
    assert req["notes"] == "Needs 2 trucks, 3 volunteers, 1 pushcart"
    assert req["request_type"] == "Delivery"
    row = next(r for r in ok(client.get("/drrmo/requests", headers=t["drrmo"]))
               if r["request_id"] == req["request_id"])
    assert row["needs"] == "Needs 2 trucks, 3 volunteers, 1 pushcart"               # 7.2 highlight
    assert row["requested_by_role"] == "CSWS Main Office" and row["created_at"]

    # An older app that still sends "drivers" is not rejected; it is ignored.
    assert "driver" not in req["notes"]

    acc = ok(client.patch(f"/drrmo/requests/{req['request_id']}/accept", headers=t["drrmo"], json={}))
    assert acc["status"] == "Accepted" and acc["scheduled_date"] is None
    assert ok(client.get("/drrmo/dashboard", headers=t["drrmo"]))["scheduled"] == 1


def test_no_truck_is_fine_when_manpower_or_a_pushcart_is_enough(api):
    client, t = api
    did = _delivery(client, t)["delivery_id"]
    req = ok(client.post("/logistics/requests", headers=t["csws"], json={
        "delivery_id": did, "trucks": 0, "volunteers": 4, "drivers": 2}), 201)
    assert req["notes"] == "Needs 4 volunteers"
