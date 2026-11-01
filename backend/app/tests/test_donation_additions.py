"""Oct 23 (Dave): add items to a pledged donation, or remove one, keeping
the SAME donation and QR (batch_reference). Batches: addition_no 1 = the
original pledge, 2+ = added later. The CMO acknowledges the donation as
one entry, added items included (no separate batch acknowledgement).

Rules: services/donation_additions.py.
"""
import core.database as database
from models.physical_donation_model import PhysicalDonation
from models.report import DisasterReport
from models.user_rbac_model import User
from services.delivery_allocation import ready_donations
from tests.test_donation_batch import LINE, _report
from tests.test_role_flows import api, ok  # noqa: F401  (fixture)

WATER = {"other_item_name": "Bottled water", "other_item_unit": "bottles",
         "packaging": "Case", "quantity": 24}


def _donate(client, t, rid):
    return ok(client.post("/donations/batch", headers=t["donor"], json={
        "report_id": rid, "handover_method": "Drop Off", "items": [LINE]}), 201)


def _add(client, t, ref, items, who="donor"):
    return client.post(f"/donations/entries/{ref}/items", headers=t[who], json={"items": items})


def _scan(client, t, ref):
    return ok(client.get(f"/donations/by-batch/{ref}", headers=t["csws"]))


def _receive(client, t, ref, ids):
    ok(client.post(f"/donations/entries/{ref}/receive", headers=t["csws"], json={
        "items": [{"donation_id": i, "actual_quantity": 2} for i in ids]}))


def _activate_everyone():
    db = database.SessionLocal()
    db.query(User).update({User.is_active: True})
    db.commit()
    db.close()


def test_old_donation_scans_as_batch_1(api):
    client, t = api
    ref = _donate(client, t, _report(client, t))["batch_reference"]
    view = _scan(client, t, ref)
    assert [b["label"] for b in view["batches"]] == ["Batch 1"]
    assert view["items"][0]["addition_no"] == 1 and view["items"][0]["added_later"] is False
    assert view["summary"]["pending"] == 1 and view["summary_text"] == "1 pending"


def test_added_items_join_the_same_donation_and_qr(api):
    client, t = api
    _activate_everyone()
    rid = _report(client, t)
    first = _donate(client, t, rid)
    ref = first["batch_reference"]

    added = ok(_add(client, t, ref, [WATER, LINE]), 201)
    assert added["batch_reference"] == ref                       # same donation
    assert added["qr_image_base64"] == first["qr_image_base64"]  # same QR image
    assert [b["label"] for b in added["batches"]] == ["Batch 1", "Batch 2"]
    later = [i for i in added["items"] if i["added_later"]]
    assert len(later) == 2 and {i["status"] for i in later} == {"Pending"}
    assert {i["qr_reference"] for i in later} == {f"{ref}-2", f"{ref}-3"}
    db = database.SessionLocal()
    assert db.query(PhysicalDonation.batch_reference).distinct().count() == 1  # no 2nd donation
    db.close()

    # CSWS sees it: a notification, and the history when scanning.
    notes = ok(client.get("/notifications/", headers=t["csws"]))["items"]
    assert any(n["type"] == "donation_items_added" for n in notes)
    assert any(h["action"] == "ADD DONATION ITEMS" for h in _scan(client, t, ref)["history"])
    # The whole-list edit is closed once items were added (history stays).
    edit = {"handover_method": "Drop Off", "items": [LINE]}
    assert client.put(f"/donations/entries/{ref}", headers=t["donor"], json=edit).status_code == 409


def test_adding_stops_once_picked_up_or_report_closed(api):
    client, t = api
    rid = _report(client, t)
    a = _donate(client, t, rid)
    _receive(client, t, a["batch_reference"], [a["items"][0]["donation_id"]])
    r = _add(client, t, a["batch_reference"], [LINE])
    assert r.status_code == 409 and "picked up or received" in r.json()["detail"]

    b = _donate(client, t, rid)
    db = database.SessionLocal()
    db.get(DisasterReport, rid).status = "Cancelled"   # the report closed
    db.commit()
    db.close()
    r = _add(client, t, b["batch_reference"], [LINE])
    assert r.status_code == 409 and "report is closed" in r.json()["detail"]

    mine = ok(client.get("/donations/mine", headers=t["donor"]))["entries"]
    blocked = {e["batch_reference"]: e for e in mine}
    assert blocked[b["batch_reference"]]["can_change_items"] is False
    assert blocked[b["batch_reference"]]["change_blocked_reason"]


def test_only_the_owner_can_add_or_remove(api):
    client, t = api
    ref = _donate(client, t, _report(client, t))["batch_reference"]
    assert _add(client, t, ref, [LINE], who="csws").status_code == 403
    assert _add(client, t, "DON-NOPE00000000", [LINE]).status_code == 404


def test_remove_needs_a_reason_keeps_one_item_and_csws_sees_why(api):
    client, t = api
    _activate_everyone()
    rid = _report(client, t)
    ref = _donate(client, t, rid)["batch_reference"]
    view = ok(_add(client, t, ref, [WATER]), 201)
    original, water = view["items"][0]["donation_id"], view["items"][1]["donation_id"]
    url = f"/donations/entries/{ref}/items/{water}/remove"

    assert client.post(url, headers=t["donor"], json={"reason": " "}).status_code == 422
    assert client.post(url, headers=t["csws"], json={"reason": "No longer"}).status_code == 403
    after = ok(client.post(url, headers=t["donor"], json={"reason": "Expired stock"}))
    gone = next(i for i in after["items"] if i["donation_id"] == water)
    assert gone["status"] == "Cancelled" and gone["removed_reason"] == "Expired stock"

    # The last item cannot be removed: a donation always keeps one.
    r = client.post(f"/donations/entries/{ref}/items/{original}/remove",
                    headers=t["donor"], json={"reason": "Changed my mind"})
    assert r.status_code == 409 and "at least one item" in r.json()["detail"]

    # CSWS sees the note when scanning, in its list without scanning, and
    # gets a notification.
    scan = _scan(client, t, ref)
    assert scan["removed_notes"][0]["reason"] == "Expired stock"
    assert scan["removed_notes"][0]["item_name"] == "Bottled water"
    assert "1 removed" in scan["summary_text"]
    listed = ok(client.get("/donations/entries", headers=t["csws"]))
    entries = [e for r_ in listed["reports"] for e in r_["entries"]] if "reports" in listed else listed
    entry = next(e for e in entries if e["batch_reference"] == ref)
    assert entry["removed_items"] == 1 and entry["removed_notes"][0]["reason"] == "Expired stock"
    notes = ok(client.get("/notifications/", headers=t["csws"]))["items"]
    assert any(n["type"] == "donation_item_removed" and "Expired stock" in n["message"] for n in notes)


def test_reinstating_keeps_removed_items_removed(api):
    client, t = api
    ref = _donate(client, t, _report(client, t))["batch_reference"]
    water = ok(_add(client, t, ref, [WATER]), 201)["items"][1]["donation_id"]
    ok(client.post(f"/donations/entries/{ref}/items/{water}/remove",
                   headers=t["donor"], json={"reason": "Expired stock"}))
    ok(client.post(f"/donations/entries/{ref}/cancel", headers=t["donor"], json={}))
    ok(client.post(f"/donations/entries/{ref}/reinstate", headers=t["csws"], json={}))
    items = {i["donation_id"]: i for i in _scan(client, t, ref)["items"]}
    assert items[water]["status"] == "Cancelled" and items[water]["removed_by_donor"]
    assert [i["status"] for k, i in items.items() if k != water] == ["Pending"]


def test_cmo_acknowledges_added_items_with_the_donation(api):
    client, t = api
    rid = _report(client, t)
    ref = _donate(client, t, rid)["batch_reference"]
    view = ok(_add(client, t, ref, [WATER]), 201)
    ids = [i["donation_id"] for i in view["items"]]

    # Not received yet: nothing for the CMO, nothing to deliver.
    assert not [e for e in ok(client.get("/cmo/entries/pending", headers=t["cmo"]))
                if e["batch_reference"] == ref]

    # CSWS receives everything in one go; the CMO sees one entry with both
    # items and acknowledges it once.
    _receive(client, t, ref, ids)
    pending = [e for e in ok(client.get("/cmo/entries/pending", headers=t["cmo"]))
               if e["batch_reference"] == ref]
    assert len(pending) == 1 and pending[0]["total_items"] == 2
    assert "batches" not in pending[0] and "cmo_status" not in pending[0]
    ok(client.post(f"/cmo/entries/{ref}/decide", headers=t["cmo"], json={"status": "Acknowledged"}))
    done = next(e for e in ok(client.get("/cmo/entries/acknowledged", headers=t["cmo"]))
                if e["batch_reference"] == ref)
    assert done["acknowledged"] is True and done["total_items"] == 2

    db = database.SessionLocal()
    ready = ready_donations(db, rid)
    db.close()
    lines = [i for e in ready["entries"] if e["batch_reference"] == ref for i in e["items"]]
    assert len(lines) == 2


def test_scan_is_staff_only(api):
    client, t = api
    ref = _donate(client, t, _report(client, t))["batch_reference"]
    for who in ("cmo", "drrmo", "brgy", "donor"):
        assert client.get(f"/donations/by-batch/{ref}", headers=t[who]).status_code == 403, who
    r = client.get("/donations/by-batch/DON-000000000000", headers=t["csws"])
    assert r.status_code == 404 and "No donation" in r.json()["detail"]
