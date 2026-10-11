"""Oct 11 notes (Dave): the CMO acknowledges a whole donation entry (one QR)
at once, and the donor's status follows by itself."""
from tests.test_donation_batch import _report
from tests.test_role_flows import api, ok  # noqa: F401  (fixture)


def _entry(client, t, rid, n=2):
    b = ok(client.post("/donations/batch", headers=t["donor"], json={
        "report_id": rid, "handover_method": "Drop Off",
        "items": [{"item_id": 1, "packaging": "Box", "quantity": q + 1} for q in range(n)]}), 201)
    return b


def test_cmo_acknowledges_a_whole_entry(api):
    client, t = api
    rid = _report(client, t)
    b = _entry(client, t, rid)
    ref = b["batch_reference"]
    # Not received yet: nothing to acknowledge
    assert client.post(f"/cmo/entries/{ref}/decide", headers=t["cmo"],
                       json={"status": "Acknowledged"}).status_code == 409
    ok(client.post(f"/donations/entries/{ref}/receive", headers=t["csws"], json={
        "items": [{"donation_id": i["donation_id"], "actual_quantity": i["quantity"]} for i in b["items"]]}))

    pend = ok(client.get("/cmo/entries/pending", headers=t["cmo"]))
    e = next(x for x in pend if x["batch_reference"] == ref)
    assert e["total_items"] == 2 and e["acknowledged"] is False
    dash = ok(client.get("/cmo/dashboard", headers=t["cmo"]))
    assert dash["pending_entries"] >= 1

    # Hold needs a reason; hold the whole entry, then acknowledge it in one tap
    assert client.post(f"/cmo/entries/{ref}/decide", headers=t["cmo"],
                       json={"status": "On Hold"}).status_code == 422
    ok(client.post(f"/cmo/entries/{ref}/decide", headers=t["cmo"],
                   json={"status": "On Hold", "notes": "Check expiry dates"}))
    e = next(x for x in ok(client.get("/cmo/entries/pending", headers=t["cmo"])) if x["batch_reference"] == ref)
    assert e["cmo_decision"] == "On Hold" and e["hold_reason"] == "Check expiry dates"

    r = ok(client.post(f"/cmo/entries/{ref}/decide", headers=t["cmo"], json={"status": "Acknowledged"}))
    assert r["items"] == 2 and r["acknowledged"] is True
    assert ref in [x["batch_reference"] for x in ok(client.get("/cmo/entries/acknowledged", headers=t["cmo"]))]

    # The donor's status follows by itself, with one notice
    mine = ok(client.get("/donations/mine", headers=t["donor"]))
    entry = next(x for x in mine["entries"] if x["batch_reference"] == ref)
    assert entry["status"] == "Confirmed"
    notes = ok(client.get("/notifications/", headers=t["donor"]))["items"]
    assert len([n for n in notes if n["type"] == "donation_confirmed"]) == 1

    # Undo for the whole entry
    ok(client.post(f"/cmo/entries/{ref}/revert", headers=t["cmo"]))
    assert ref in [x["batch_reference"] for x in ok(client.get("/cmo/entries/pending", headers=t["cmo"]))]
    assert client.post(f"/cmo/entries/{ref}/decide", headers=t["donor"],
                       json={"status": "Acknowledged"}).status_code == 403
