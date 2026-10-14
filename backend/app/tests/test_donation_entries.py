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

# ------------------------------------------------ POST /donations/entries/{ref}/receive

def _inv(client, t, rid):
    rows = ok(client.get(f"/donations/inventory?report_id={rid}", headers=t["csws"]))
    return {r["item_id"]: r["quantity"] for r in rows}


def test_receive_entry_receives_listed_items_with_actual_quantities(api):
    client, t = api
    rid = _report(client, t)
    e = _entry(client, t["donor"], rid, 3)
    ids = [i["donation_id"] for i in e["items"]]
    ref = e["batch_reference"]

    # UC-CM1 alt 4a: 1 of 2 accepted on the first item; alt 4b: third item left out.
    body = ok(client.post(f"/donations/entries/{ref.lower()}/receive", headers=t["csws"], json={
        "items": [{"donation_id": ids[0], "actual_quantity": 1},
                  {"donation_id": ids[1], "actual_quantity": 2}],
        "notes": "one box damaged",
    }))
    assert body["batch_reference"] == ref and body["pending_items"] == 1
    assert _inv(client, t, rid) == {1: 3}            # same inventory path as single receive

    entry = ok(client.get("/donations/entries", headers=t["csws"]))["reports"][0]["entries"][0]
    got = {i["donation_id"]: (i["status"], i["actual_quantity_received"]) for i in entry["items"]}
    assert got == {ids[0]: ("Received", 1), ids[1]: ("Received", 2), ids[2]: ("Pending", None)}
    assert entry["status"] == "Partly Received"
    pending = ok(client.get("/donations/entries?pending_only=true", headers=t["csws"]))
    assert pending["total_entries"] == 1             # still waiting on the third item

    ok(client.post(f"/donations/entries/{ref}/receive", headers=t["admin"], json={
        "items": [{"donation_id": ids[2], "actual_quantity": 2}]}))
    assert ok(client.get("/donations/entries?pending_only=true", headers=t["csws"]))["total_entries"] == 0
    assert _inv(client, t, rid) == {1: 5}


def test_receive_entry_is_all_or_nothing(api):
    client, t = api
    rid = _report(client, t)
    e = _entry(client, t["donor"], rid, 2)
    other = _entry(client, t["donor"], rid, 1)
    ids = [i["donation_id"] for i in e["items"]]
    ref = e["batch_reference"]
    ok(client.post("/donations/receive", headers=t["csws"],
                   json={"donation_id": ids[1], "actual_quantity": 2}))
    before = _inv(client, t, rid)

    def post(items):
        return client.post(f"/donations/entries/{ref}/receive", headers=t["csws"], json={"items": items})

    # second item already Received -> nothing from this call is kept
    assert post([{"donation_id": ids[0], "actual_quantity": 2},
                 {"donation_id": ids[1], "actual_quantity": 2}]).status_code == 400
    # item from another entry
    assert post([{"donation_id": ids[0], "actual_quantity": 2},
                 {"donation_id": other["items"][0]["donation_id"], "actual_quantity": 2}]).status_code == 400
    # same item twice, zero quantity, empty list
    assert post([{"donation_id": ids[0], "actual_quantity": 1}] * 2).status_code == 400
    assert post([{"donation_id": ids[0], "actual_quantity": 0}]).status_code == 422
    assert post([]).status_code == 422
    assert _inv(client, t, rid) == before
    entry = [x for x in ok(client.get("/donations/entries", headers=t["csws"]))["reports"][0]["entries"]
             if x["batch_reference"] == ref][0]
    assert entry["items"][0]["status"] == "Pending"

    assert client.post("/donations/entries/DON-NOPE/receive", headers=t["csws"],
                       json={"items": [{"donation_id": ids[0], "actual_quantity": 1}]}).status_code == 404


def test_receive_entry_roles(api):
    client, t = api
    rid = _report(client, t)
    e = _entry(client, t["donor"], rid, 1)
    body = {"items": [{"donation_id": e["items"][0]["donation_id"], "actual_quantity": 2}]}
    url = f"/donations/entries/{e['batch_reference']}/receive"
    for role in ("donor", "cmo", "unit"):
        assert client.post(url, headers=t[role], json=body).status_code == 403
    assert client.post(url, json=body).status_code == 401
