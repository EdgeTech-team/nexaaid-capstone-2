"""Oct 13 concerns: whose goods go on a delivery, and the donor's timeline.

A delivery takes every donation of its report that the CMO acknowledged
(Oct 13, team), and each donor's timeline follows that delivery. Typed
quantities (the old way) still take first received first. "Not brought" at
receiving closes an item instead of leaving the entry Partly Received.
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


def _deliver_all(client, t, rid):
    """What the app does: no quantities, the whole report."""
    return client.post("/deliveries/", headers=t["csws"], json={
        "report_id": rid, "destination_barangay_id": 1, "delivery_date": "2026-10-20T08:00:00"})


def test_a_delivery_takes_every_acknowledged_donation_of_the_report(api):
    """Oct 13 (team): donations are for their report, so every acknowledged
    donation goes; ones still waiting for the CMO wait for the next one."""
    client, t = api
    rid = _report(client, t)
    liza, ana = _give(client, t, rid, 50), _give(client, t, rid, 30)
    waiting = _give(client, t, rid, 20, ack=False)

    ready = ok(client.get(f"/deliveries/ready/{rid}", headers=t["csws"]))
    assert [e["batch_reference"] for e in ready["entries"]] == [liza["batch_reference"], ana["batch_reference"]]
    assert [(i["item_id"], i["quantity"]) for i in ready["totals"]] == [(1, 80)]
    assert ready["waiting_for_cmo"] == 1
    assert client.get(f"/deliveries/ready/{rid}", headers=t["donor"]).status_code == 403

    r = _deliver_all(client, t, rid)
    assert r.status_code == 201, r.text
    assert [(i["item_id"], i["quantity"]) for i in r.json()["items"]] == [(1, 80)]
    ok(client.post(f"/deliveries/{r.json()['delivery_id']}/advance", headers=t["csws"]))   # In Transit
    for b in (liza, ana):
        e = _entry(client, t, b["batch_reference"])
        assert e["lifecycle_status"] == "In Transit" and e["delivery_note"] is None
    assert _entry(client, t, waiting["batch_reference"])["lifecycle_status"] == "Received"

    # Nothing acknowledged left: the next delivery has nothing to take.
    r = _deliver_all(client, t, rid)
    assert r.status_code == 409 and "acknowledged" in r.json()["detail"]
    # Once the CMO acknowledges it, the waiting donation goes next.
    ok(client.post(f"/cmo/entries/{waiting['batch_reference']}/decide", headers=t["cmo"],
                   json={"status": "Acknowledged"}))
    ready = ok(client.get(f"/deliveries/ready/{rid}", headers=t["csws"]))
    assert [e["batch_reference"] for e in ready["entries"]] == [waiting["batch_reference"]]
    assert _deliver_all(client, t, rid).status_code == 201


def test_a_trip_takes_every_acknowledged_donation_of_each_report(api):
    client, t = api
    rid = _report(client, t)
    b = _give(client, t, rid, 12)
    r = client.post("/trips/", headers=t["csws"], json={
        "trip_date": "2026-10-20T08:00:00", "reports": [{"report_id": rid}]})
    assert r.status_code == 201, r.text
    assert r.json()["total_quantity"] == 12
    assert _entry(client, t, b["batch_reference"])["lifecycle_status"] == "Confirmed"   # still Preparing


def test_typed_quantities_still_take_first_received_first(api):
    """Deliveries made the old way (typed quantities, e.g. before Oct 13)
    can take part of a donation; the donor then sees a note until the rest
    goes."""
    client, t = api
    rid = _report(client, t)
    liza, ana = _give(client, t, rid, 50), _give(client, t, rid, 30)
    did = _deliver(client, t, rid, 65)
    ok(client.post(f"/deliveries/{did}/advance", headers=t["csws"]))
    assert _entry(client, t, liza["batch_reference"])["lifecycle_status"] == "In Transit"
    e = _entry(client, t, ana["batch_reference"])
    assert e["lifecycle_status"] == "Confirmed" and e["delivery_note"].startswith("Rice: 15 of 30 kg sent")
    # The whole-report delivery then takes Ana's other 15.
    ready = ok(client.get(f"/deliveries/ready/{rid}", headers=t["csws"]))
    assert [(e["batch_reference"], e["items"][0]["quantity"]) for e in ready["entries"]] == [(ana["batch_reference"], 15)]
    did2 = _deliver_all(client, t, rid).json()["delivery_id"]
    ok(client.post(f"/deliveries/{did2}/advance", headers=t["csws"]))
    e = _entry(client, t, ana["batch_reference"])
    assert e["lifecycle_status"] == "In Transit" and e["delivery_note"] is None


def test_a_cancelled_delivery_frees_its_donations(api):
    client, t = api
    rid = _report(client, t)
    b = _give(client, t, rid, 20)
    did = _deliver_all(client, t, rid).json()["delivery_id"]
    assert ok(client.get(f"/deliveries/ready/{rid}", headers=t["csws"]))["entries"] == []
    ok(client.post(f"/deliveries/{did}/cancel", headers=t["csws"], json={"reason": "Truck broke down"}))
    ready = ok(client.get(f"/deliveries/ready/{rid}", headers=t["csws"]))
    assert [e["batch_reference"] for e in ready["entries"]] == [b["batch_reference"]]


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


def test_main_office_picks_whole_entries_and_the_rest_waits(api):
    """Oct 15 (team): too much for one truck? Donor A's and B's entries go,
    donor C's waits for the next delivery. An entry always goes whole."""
    client, t = api
    rid = _report(client, t)
    a, b, cc = _give(client, t, rid, 50), _give(client, t, rid, 30), _give(client, t, rid, 20)
    r = client.post("/deliveries/", headers=t["csws"], json={
        "report_id": rid, "destination_barangay_id": 1, "delivery_date": "2026-10-20T08:00:00",
        "batch_references": [a["batch_reference"], b["batch_reference"]]})
    assert r.status_code == 201, r.text
    assert [(i["item_id"], i["quantity"]) for i in r.json()["items"]] == [(1, 80)]
    ok(client.post(f"/deliveries/{r.json()['delivery_id']}/advance", headers=t["csws"]))
    assert _entry(client, t, a["batch_reference"])["lifecycle_status"] == "In Transit"
    assert _entry(client, t, b["batch_reference"])["lifecycle_status"] == "In Transit"
    assert _entry(client, t, cc["batch_reference"])["lifecycle_status"] == "Confirmed"   # waits
    ready = ok(client.get(f"/deliveries/ready/{rid}", headers=t["csws"]))
    assert [e["batch_reference"] for e in ready["entries"]] == [cc["batch_reference"]]

    # An entry already sent (or not this report's) cannot be picked.
    r = client.post("/deliveries/", headers=t["csws"], json={
        "report_id": rid, "destination_barangay_id": 1, "delivery_date": "2026-10-20T08:00:00",
        "batch_references": [a["batch_reference"]]})
    assert r.status_code == 409 and a["batch_reference"] in r.json()["detail"]
    # Next trip takes C, whole.
    r = client.post("/trips/", headers=t["csws"], json={"trip_date": "2026-10-21T08:00:00",
        "reports": [{"report_id": rid, "batch_references": [cc["batch_reference"]]}]})
    assert r.status_code == 201, r.text
    assert r.json()["total_quantity"] == 20
