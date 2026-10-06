"""GET /donations/entries: Report -> Entries -> Items."""
from tests.test_role_flows import api, ok  # noqa: F401  (fixture)
from tests.test_donation_batch import _report


def _entry(client, headers, rid, n_items):
    return ok(client.post("/donations/batch", headers=headers, json={
        "report_id": rid,
        "handover_method": "Drop Off",
        "items": [{"item_id": 1, "packaging": "Box", "quantity": 2} for _ in range(n_items)],
    }), 201)


def test_entries_grouped_by_report_then_entry(api):
    client, t = api
    r1, r2 = _report(client, t), _report(client, t)
    a1 = _entry(client, t["donor"], r1, 3)
    a2 = _entry(client, t["donor"], r1, 1)
    _entry(client, t["donor"], r2, 2)

    data = ok(client.get("/donations/entries", headers=t["csws"]))
    assert data["total_reports"] == 2 and data["total_entries"] == 3
    reports = {r["report_id"]: r for r in data["reports"]}

    first, second = reports[r1]["entries"]
    assert [first["batch_reference"], second["batch_reference"]] == [a1["batch_reference"], a2["batch_reference"]]
    assert [first["entry_no"], second["entry_no"]] == [1, 2]
    assert [len(first["items"]), len(second["items"])] == [3, 1]
    assert reports[r1]["total_items"] == 4
    assert reports[r2]["entries"][0]["entry_no"] == 1
    assert first["donor"]                       # staff see who donated

    only_r2 = ok(client.get(f"/donations/entries?report_id={r2}", headers=t["admin"]))
    assert [r["report_id"] for r in only_r2["reports"]] == [r2]


def test_pending_only_follows_receiving(api):
    client, t = api
    rid = _report(client, t)
    e = _entry(client, t["donor"], rid, 2)
    ids = [i["donation_id"] for i in e["items"]]

    def pending():
        return ok(client.get("/donations/entries?pending_only=true", headers=t["csws"]))["total_entries"]

    assert pending() == 1
    ok(client.post("/donations/receive", headers=t["csws"],
                   json={"donation_id": ids[0], "actual_quantity": 2}))
    entry = ok(client.get("/donations/entries", headers=t["csws"]))["reports"][0]["entries"][0]
    assert entry["status"] == "Partly Received" and entry["pending_items"] == 1
    assert pending() == 1                       # one item still waiting
    ok(client.post("/donations/receive", headers=t["csws"],
                   json={"donation_id": ids[1], "actual_quantity": 2}))
    assert pending() == 0


def test_donor_sees_only_own_entries_and_other_roles_blocked(api):
    client, t = api
    rid = _report(client, t)
    _entry(client, t["donor"], rid, 2)
    ok(client.post("/donations/batch", json={
        "report_id": rid,
        "handover_method": "Drop Off",
        "items": [{"item_id": 1, "packaging": "Box", "quantity": 1}],
        "guest_donor": {"full_name": "Guest", "contact_number": "0917 123 4567"},
    }), 201)

    mine = ok(client.get("/donations/entries", headers=t["donor"]))
    assert mine["total_entries"] == 1
    assert "donor" not in mine["reports"][0]["entries"][0]
    assert ok(client.get("/donations/entries", headers=t["csws"]))["total_entries"] == 2
    assert client.get("/donations/entries", headers=t["unit"]).status_code == 403
    assert client.get("/donations/entries").status_code == 401