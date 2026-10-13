"""Oct 13 concerns: whose goods go on a delivery, and the donor's timeline.

Liza gives 50 kg, Ana gives 30 kg (both received and acknowledged). CSWS
sends 65 kg -> all 50 of Liza's and 15 of Ana's (first received, first
sent). Liza's donation follows the delivery; Ana's stays acknowledged with
"15 of 30 kg sent" until the rest goes too. And "Not brought" at receiving
closes an item instead of leaving the entry Partly Received.
"""
from tests.test_donation_batch import _report
from tests.test_role_flows import api, ok  # noqa: F401  (fixture)


def _give(client, t, rid, qty, ack=True, n_items=1):
    b = ok(client.post("/donations/batch", headers=t["donor"], json={
        "report_id": rid, "handover_method": "Drop Off",
        "items": [{"item_id": 1, "packaging": "Sack", "quantity": qty}] * n_items}), 201)
    first = b["items"][0]
    ok(client.post(f"/donations/entries/{b['batch_reference']}/receive", headers=t["csws"], json={
        "items": [{"donation_id": first["donation_id"], "actual_quantity": qty}]}))
    if ack:
        ok(client.post(f"/cmo/entries/{b['batch_reference']}/decide", headers=t["cmo"],
                       json={"status": "Acknowledged"}))
    return b


def _deliver(client, t, rid, qty):
    return ok(client.post("/deliveries/", headers=t["csws"], json={
        "report_id": rid, "destination_barangay_id": 1,
        "delivery_date": "2026-10-20T08:00:00", "items": [{"item_id": 1, "quantity": qty}],
    }), 201)["delivery_id"]


def _entry(client, t, ref):
    mine = ok(client.get("/donations/mine", headers=t["donor"]))
    return next(e for e in mine["entries"] if e["batch_reference"] == ref)


def test_first_received_first_sent_and_the_donor_timeline(api):
    client, t = api
    rid = _report(client, t)
    liza, ana = _give(client, t, rid, 50), _give(client, t, rid, 30)

    # Preparing: the preview says whose goods 65 takes, and 80 finishes Ana's.
    p = ok(client.post("/deliveries/preview-allocation", headers=t["csws"], json={
        "report_id": rid, "items": [{"item_id": 1, "quantity": 65}]}))["items"][0]
    assert [(d["batch_reference"], d["take"], d["whole"]) for d in p["donations"]] == [
        (liza["batch_reference"], 50, True), (ana["batch_reference"], 15, False)]
    assert p["finish_quantity"] == 80
    assert client.post("/deliveries/preview-allocation", headers=t["donor"], json={
        "report_id": rid, "items": [{"item_id": 1, "quantity": 65}]}).status_code == 403

    did = _deliver(client, t, rid, 65)
    # Still at the office: nobody's step moves yet.
    assert _entry(client, t, liza["batch_reference"])["lifecycle_status"] == "Confirmed"

    ok(client.post(f"/deliveries/{did}/advance", headers=t["csws"]))   # In Transit
    e_liza, e_ana = _entry(client, t, liza["batch_reference"]), _entry(client, t, ana["batch_reference"])
    assert e_liza["lifecycle_status"] == "In Transit" and e_liza["delivery_note"] is None
    assert e_ana["lifecycle_status"] == "Confirmed"          # only part of it left
    assert e_ana["delivery_note"].startswith("Rice: 15 of 30 kg sent")

    ok(client.post(f"/deliveries/{did}/advance", headers=t["csws"]))   # Delivered
    assert _entry(client, t, liza["batch_reference"])["lifecycle_status"] == "Delivered"

    # The other 15 go on the next truck: Ana's whole donation is on its way.
    p = ok(client.post("/deliveries/preview-allocation", headers=t["csws"], json={
        "report_id": rid, "items": [{"item_id": 1, "quantity": 15}]}))["items"][0]
    assert [(d["take"], d["whole"]) for d in p["donations"]] == [(15, True)]
    did2 = _deliver(client, t, rid, 15)
    ok(client.post(f"/deliveries/{did2}/advance", headers=t["csws"]))
    e_ana = _entry(client, t, ana["batch_reference"])
    assert e_ana["lifecycle_status"] == "In Transit" and e_ana["delivery_note"] is None


def test_acknowledged_goods_go_first_and_cancelled_deliveries_free_them(api):
    client, t = api
    rid = _report(client, t)
    waiting = _give(client, t, rid, 20, ack=False)   # received first, CMO not yet
    acked = _give(client, t, rid, 20)
    p = ok(client.post("/deliveries/preview-allocation", headers=t["csws"], json={
        "report_id": rid, "items": [{"item_id": 1, "quantity": 20}]}))["items"][0]
    assert [d["batch_reference"] for d in p["donations"]] == [acked["batch_reference"]]

    did = _deliver(client, t, rid, 20)
    ok(client.post(f"/deliveries/{did}/cancel", headers=t["csws"], json={"reason": "Truck broke down"}))
    # Cancelled: the acknowledged goods are free again and go first next time.
    p = ok(client.post("/deliveries/preview-allocation", headers=t["csws"], json={
        "report_id": rid, "items": [{"item_id": 1, "quantity": 30}]}))["items"][0]
    assert [(d["batch_reference"], d["take"]) for d in p["donations"]] == [
        (acked["batch_reference"], 20), (waiting["batch_reference"], 10)]


def test_not_brought_closes_the_item_instead_of_partly_received(api):
    client, t = api
    rid = _report(client, t)
    b = ok(client.post("/donations/batch", headers=t["donor"], json={
        "report_id": rid, "handover_method": "Drop Off",
        "items": [{"item_id": 1, "packaging": "Sack", "quantity": 5},
                  {"item_id": 1, "packaging": "Box", "quantity": 3}]}), 201)
    one, two = (i["donation_id"] for i in b["items"])
    ref = b["batch_reference"]
    assert client.post(f"/donations/entries/{ref}/receive", headers=t["csws"], json={}).status_code == 400

    r = ok(client.post(f"/donations/entries/{ref}/receive", headers=t["csws"], json={
        "items": [{"donation_id": one, "actual_quantity": 5}], "not_brought": [two]}))
    assert r["pending_items"] == 0 and r["not_brought"] == [two]
    e = _entry(client, t, ref)
    assert e["status"] == "Received"                       # not Partly Received
    item = next(i for i in e["items"] if i["donation_id"] == two)
    assert item["status"] == "Cancelled" and e["close_reason"] == "Not brought to CSWS"
    # Already closed: it cannot be marked again.
    assert client.post(f"/donations/entries/{ref}/receive", headers=t["csws"], json={
        "not_brought": [two]}).status_code == 409
