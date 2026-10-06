"""I4: CSWS picks how many trucks, drivers and volunteers. DRRMO just accepts."""
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

    assert post("csws", {"delivery_id": did}).status_code == 422                     # counts required
    assert post("csws", {"delivery_id": did, "trucks": 0, "drivers": 1, "volunteers": 0}).status_code == 422
    assert post("csws", {"delivery_id": did, "trucks": 99, "drivers": 1, "volunteers": 0}).status_code == 422

    body = {"delivery_id": did, "trucks": 2, "drivers": 2, "volunteers": 3}
    assert post("drrmo", body).status_code == 403                                     # only CSWS
    req = ok(post("csws", body), 201)
    assert req["notes"] == "Needs 2 trucks, 2 drivers, 3 volunteers"

    acc = ok(client.patch(f"/drrmo/requests/{req['request_id']}/accept", headers=t["drrmo"], json={}))
    assert acc["status"] == "Accepted" and acc["scheduled_date"] is None
    assert ok(client.get("/drrmo/dashboard", headers=t["drrmo"]))["scheduled"] == 1