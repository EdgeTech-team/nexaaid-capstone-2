"""
Appendix H 4.4 View Donation Records / 4.5 Monitor Donation Status:
records are listed per donation entry (one QR / batch_reference) with their
items, for staff (GET /donations/records) and for the donor's own records
(GET /donations/mine "entries", UC-D3 / UC-R3), with filtering and sorting.
"""
from tests.test_donation_batch import LINE, _pickup_slot, _report
from tests.test_role_flows import api, ok  # noqa: F401  (fixture)


def test_records_are_per_entry_with_filters_and_sorting(api):
    client, t = api
    rid = _report(client, t)
    other_rid = _report(client, t)
    big = ok(client.post("/donations/batch", headers=t["donor"], json={
        "report_id": rid, "handover_method": "Drop Off",
        "items": [LINE, {**LINE, "packaging": "Pack"}, {**LINE, "quantity": 7}]}), 201)
    small = ok(client.post("/donations/batch", headers=t["donor"], json={
        "report_id": other_rid, "handover_method": "Door to Door",
        "pickup_address": "1 Test St, Mandaue City",
        "preferred_pickup_at": _pickup_slot().isoformat(),
        "items": [LINE]}), 201)

    # One record per entry, newest first, each with its items and donor
    recs = ok(client.get("/donations/records", headers=t["admin"]))
    assert [e["batch_reference"] for e in recs] == [small["batch_reference"], big["batch_reference"]]
    first_big = next(e for e in recs if e["batch_reference"] == big["batch_reference"])
    assert first_big["total_items"] == 3 and len(first_big["items"]) == 3
    assert first_big["total_quantity"] == 11 and first_big["entry_no"] == 1
    assert first_big["donor"] and first_big["on_hold_items"] == 0

    # Sorting
    oldest = ok(client.get("/donations/records", params={"sort": "oldest"}, headers=t["csws"]))
    assert oldest[0]["batch_reference"] == big["batch_reference"]
    most = ok(client.get("/donations/records", params={"sort": "most_items"}, headers=t["cmo"]))
    assert most[0]["batch_reference"] == big["batch_reference"]
    fewest = ok(client.get("/donations/records", params={"sort": "fewest_items"}, headers=t["cmo"]))
    assert fewest[0]["batch_reference"] == small["batch_reference"]
    assert client.get("/donations/records", params={"sort": "bogus"}, headers=t["admin"]).status_code == 422

    # Filtering: report, handover method, search
    by_report = ok(client.get("/donations/records", params={"report_id": rid}, headers=t["admin"]))
    assert [e["batch_reference"] for e in by_report] == [big["batch_reference"]]
    door = ok(client.get("/donations/records", params={"handover_method": "Door to Door"}, headers=t["admin"]))
    assert [e["batch_reference"] for e in door] == [small["batch_reference"]]
    found = ok(client.get("/donations/records", params={"q": big["batch_reference"].lower()}, headers=t["admin"]))
    assert [e["batch_reference"] for e in found] == [big["batch_reference"]]

    # 4.5 status per entry: receiving one item makes the entry Partly Received
    ok(client.post("/donations/receive", headers=t["csws"],
                   json={"donation_id": big["items"][0]["donation_id"], "actual_quantity": 2}))
    partly = ok(client.get("/donations/records", params={"status": "Partly Received"}, headers=t["admin"]))
    assert [e["batch_reference"] for e in partly] == [big["batch_reference"]]
    pending = ok(client.get("/donations/records", params={"status": "Pending"}, headers=t["admin"]))
    assert [e["batch_reference"] for e in pending] == [small["batch_reference"]]

    # CMO hold shows on the entry and its item
    held = big["items"][0]["donation_id"]
    ok(client.post(f"/cmo/donations/{held}/confirm", headers=t["cmo"],
                   json={"status": "On Hold", "notes": "Check the count"}), 201)
    rec = ok(client.get("/donations/records", params={"q": big["batch_reference"]}, headers=t["admin"]))[0]
    assert rec["on_hold_items"] == 1
    assert next(i for i in rec["items"] if i["donation_id"] == held)["hold_reason"] == "Check the count"

    # Roles outside 4.4 / 4.5 access
    for role in ("drrmo", "donor", "unit"):
        ok(client.get("/donations/records", headers=t[role]), 403)

    # The donor's own records are per entry too, newest first
    mine = ok(client.get("/donations/mine", headers=t["donor"]))
    assert [e["batch_reference"] for e in mine["entries"]] == [small["batch_reference"], big["batch_reference"]]
    assert mine["summary"]["total_entries"] == 2
    mine_big = mine["entries"][1]
    assert mine_big["status"] == "Partly Received" and mine_big["report"]["report_id"] == rid
    assert mine_big["on_hold_items"] == 1 and "donor" not in mine_big
    assert mine["entries"][0]["pickup_address"] == "1 Test St, Mandaue City"


def test_barangay_rep_sees_only_its_own_barangays_records(api):
    """Reminder (4.4): the Barangay Receiving Representative has donation
    records too, only for reports in its assigned barangay, enforced by the
    backend (UC-B1 alt 3a), and without donor names or CMO notes."""
    client, t = api
    own = _report(client, t)  # barangay 1 = "brgy"'s barangay
    other = ok(client.post("/reports/", headers=t["unit"], json={
        "disaster_type_id": 1, "barangay_id": 2, "estimated_quantity": 50}), 201)["report_id"]
    ok(client.post(f"/reports/{other}/validate", headers=t["admin"], json={}))
    mine = ok(client.post("/donations/batch", headers=t["donor"], json={
        "report_id": own, "handover_method": "Drop Off", "items": [LINE]}), 201)
    theirs = ok(client.post("/donations/batch", headers=t["donor"], json={
        "report_id": other, "handover_method": "Drop Off", "items": [LINE, LINE]}), 201)

    recs = ok(client.get("/donations/records", headers=t["brgy"]))
    assert [e["batch_reference"] for e in recs] == [mine["batch_reference"]]
    assert "donor" not in recs[0] and "on_hold_items" not in recs[0]
    # Same filters and sort as staff; another barangay's report gives nothing
    assert ok(client.get("/donations/records", params={"report_id": other},
                         headers=t["brgy"])) == []
    assert ok(client.get("/donations/records", params={"status": "Pending", "sort": "most_items"},
                         headers=t["brgy"]))[0]["batch_reference"] == mine["batch_reference"]
    # The other barangay's representative sees only its own
    recs2 = ok(client.get("/donations/records", headers=t["brgy2"]))
    assert [e["batch_reference"] for e in recs2] == [theirs["batch_reference"]]
    # Staff still see both, with donor names
    staff = ok(client.get("/donations/records", headers=t["admin"]))
    assert {e["batch_reference"] for e in staff} == {mine["batch_reference"], theirs["batch_reference"]}
    assert all(e["donor"] for e in staff)
