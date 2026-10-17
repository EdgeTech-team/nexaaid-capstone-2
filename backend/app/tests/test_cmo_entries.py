"""Oct 11 notes (Dave): the CMO acknowledges a whole donation entry (one QR)
at once, and the donor's status follows by itself."""
import core.database as database
from models.user_rbac_model import User
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


def test_cmo_hears_only_after_csws_receives_and_opens_that_entry(api):
    """problema_napud 4.1: no CMO notification for a pledge; one after CSWS
    Main Office receives it, pointing at the entry, which opens whole
    (GET /cmo/entries/by-donation/{id}) for Acknowledge / Close."""
    client, t = api
    # The fixture's users keep the text server default 'true' on SQLite,
    # which user_ids_with_role (is_active IS 1) does not match. Store a
    # real boolean, as Postgres has, so role notifications reach them.
    db = database.SessionLocal()
    db.query(User).update({User.is_active: True})
    db.commit()
    db.close()

    def cmo_notes():
        items = ok(client.get("/notifications/", headers=t["cmo"]))["items"]
        return [n for n in items if n["type"] == "donation_awaiting_confirmation"]

    rid = _report(client, t)
    b = _entry(client, t, rid)
    ref = b["batch_reference"]
    first = b["items"][0]["donation_id"]
    assert cmo_notes() == []
    assert client.get(f"/cmo/entries/by-donation/{first}", headers=t["cmo"]).status_code == 404

    ok(client.post(f"/donations/entries/{ref}/receive", headers=t["csws"], json={
        "items": [{"donation_id": i["donation_id"], "actual_quantity": i["quantity"]} for i in b["items"]]}))
    [note] = cmo_notes()
    assert note["entity_type"] == "donation" and note["entity_id"] == first

    e = ok(client.get(f"/cmo/entries/by-donation/{note['entity_id']}", headers=t["cmo"]))
    assert e["batch_reference"] == ref and e["total_items"] == 2 and e["acknowledged"] is False
    assert client.get(f"/cmo/entries/by-donation/{first}", headers=t["donor"]).status_code == 403
    assert client.get("/cmo/entries/by-donation/999999", headers=t["cmo"]).status_code == 404


def test_main_office_hears_when_the_cmo_acknowledges_or_holds_an_entry(api):
    """Oct 17 (Mark): CSWS Main Office is told once per entry when the CMO
    acknowledges it (it can now go on a delivery) or puts it on hold."""
    client, t = api
    db = database.SessionLocal()
    db.query(User).update({User.is_active: True})   # see the test above
    db.commit()
    db.close()

    def office_notes(kind):
        items = ok(client.get("/notifications/", headers=t["csws"]))["items"]
        return [n for n in items if n["type"] == kind]

    rid = _report(client, t)
    b = _entry(client, t, rid)
    ref = b["batch_reference"]
    ok(client.post(f"/donations/entries/{ref}/receive", headers=t["csws"], json={
        "items": [{"donation_id": i["donation_id"], "actual_quantity": i["quantity"]} for i in b["items"]]}))

    ok(client.post(f"/cmo/entries/{ref}/decide", headers=t["cmo"],
                   json={"status": "On Hold", "notes": "Check expiry dates"}))
    held = office_notes("donation_held_staff")
    assert len(held) == 1 and ref in held[0]["message"] and "Check expiry dates" in held[0]["message"]

    ok(client.post(f"/cmo/entries/{ref}/decide", headers=t["cmo"], json={"status": "Acknowledged"}))
    ready = office_notes("donation_ready_for_delivery")
    assert len(ready) == 1                                   # one per entry, not per item
    assert ref in ready[0]["message"] and f"#{rid} " in ready[0]["message"]
    assert ready[0]["entity_type"] == "donation"
    # Only Main Office: the CMO itself is not told.
    assert not [n for n in ok(client.get("/notifications/", headers=t["cmo"]))["items"]
                if n["type"] == "donation_ready_for_delivery"]
