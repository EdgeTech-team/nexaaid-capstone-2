"""Advisor (Oct 24): after CSWS asks DRRMO for transport, DRRMO (not CSWS)
marks the delivery In Transit when it picks the goods up."""
from tests.test_logistics_needs import _delivery
from tests.test_role_flows import api, ok  # noqa: F401  (fixture)


def test_drrmo_marks_in_transit_once_it_takes_the_request(api):
    client, t = api
    did = _delivery(client, t)["delivery_id"]
    req = ok(client.post("/logistics/requests", headers=t["csws"],
                         json={"delivery_id": did, "trucks": 1}), 201)
    rid = req["request_id"]

    # Waiting for DRRMO: CSWS can't send it, DRRMO can't pick up yet.
    r = client.post(f"/deliveries/{did}/advance", headers=t["csws"])
    assert r.status_code == 409 and "DRRMO marks it In Transit" in r.text
    assert client.post(f"/drrmo/requests/{rid}/picked-up", headers=t["drrmo"]).status_code == 409

    ok(client.patch(f"/drrmo/requests/{rid}/accept", headers=t["drrmo"], json={}))
    assert client.post(f"/deliveries/{did}/advance", headers=t["csws"]).status_code == 409
    assert client.post(f"/drrmo/requests/{rid}/picked-up", headers=t["csws"]).status_code == 403

    row = ok(client.post(f"/drrmo/requests/{rid}/picked-up", headers=t["drrmo"]))
    assert row["delivery_status"] == "In Transit" and row["stage"] == "In Transit"
    assert client.post(f"/drrmo/requests/{rid}/picked-up", headers=t["drrmo"]).status_code == 409

    # Testing (Oct 27): DRRMO also marks it Delivered; CSWS still waits.
    r = client.post(f"/deliveries/{did}/advance", headers=t["csws"])
    assert r.status_code == 409 and "DRRMO marks it Delivered" in r.text
    assert client.post(f"/drrmo/requests/{rid}/delivered", headers=t["csws"]).status_code == 403
    row = ok(client.post(f"/drrmo/requests/{rid}/delivered", headers=t["drrmo"]))
    assert row["delivery_status"] == "Delivered"
    assert client.post(f"/drrmo/requests/{rid}/delivered", headers=t["drrmo"]).status_code == 409


def test_without_a_drrmo_request_csws_still_sends_it(api):
    client, t = api
    did = _delivery(client, t)["delivery_id"]
    assert ok(client.post(f"/deliveries/{did}/advance", headers=t["csws"]))["status"] == "In Transit"


def test_cancelling_the_request_lets_csws_send_it(api):
    client, t = api
    did = _delivery(client, t)["delivery_id"]
    rid = ok(client.post("/logistics/requests", headers=t["csws"],
                         json={"delivery_id": did, "trucks": 1}), 201)["request_id"]
    ok(client.post(f"/logistics/requests/{rid}/cancel", headers=t["csws"],
                   json={"reason": "We found our own truck"}))
    assert ok(client.post(f"/deliveries/{did}/advance", headers=t["csws"]))["status"] == "In Transit"
