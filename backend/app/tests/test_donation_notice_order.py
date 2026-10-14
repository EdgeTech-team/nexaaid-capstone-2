"""Daniel (Oct 10): the donor hears about the donation entry in order:
submitted -> received by CSWS -> acknowledged by the CMO. The CMO can only
acknowledge goods CSWS received, and the donor gets one "acknowledged"
notice per entry (not one per item), naming the QR reference."""
from tests.test_donation_batch import _report
from tests.test_role_flows import api, ok  # noqa: F401  (fixture)


def _titles(client, headers):
    return [n["title"] for n in ok(client.get("/notifications/", headers=headers))["items"]]


def test_donor_is_told_in_order_once_per_entry(api):
    client, t = api
    rid = _report(client, t)
    b = ok(client.post("/donations/batch", headers=t["donor"], json={
        "report_id": rid, "handover_method": "Drop Off",
        "items": [{"item_id": 1, "packaging": "Box", "quantity": 2},
                  {"item_id": 1, "packaging": "Sack", "quantity": 5}],
    }), 201)
    ref, items = b["batch_reference"], b["items"]

    # The CMO cannot acknowledge before CSWS receives
    r = client.post(f"/cmo/donations/{items[0]['donation_id']}/confirm", headers=t["cmo"],
                    json={"status": "Confirmed"})
    assert r.status_code == 400

    ok(client.post(f"/donations/entries/{ref}/receive", headers=t["csws"], json={
        "items": [{"donation_id": i["donation_id"], "actual_quantity": i["quantity"]} for i in items]}))
    assert f"Donation entry {ref} received" in _titles(client, t["donor"])

    for i in items:
        ok(client.post(f"/cmo/donations/{i['donation_id']}/confirm", headers=t["cmo"],
                       json={"status": "Confirmed"}), 201)
    notes = ok(client.get("/notifications/", headers=t["donor"]))["items"]
    acknowledged = [n for n in notes if n["type"] == "donation_confirmed"]
    assert len(acknowledged) == 1 and ref in acknowledged[0]["message"]
    # Newest first: acknowledged, received, submitted
    order = [n["type"] for n in notes if n["type"].startswith("donation_")]
    assert order[:3] == ["donation_confirmed", "donation_received", "donation_submitted_confirm"]
