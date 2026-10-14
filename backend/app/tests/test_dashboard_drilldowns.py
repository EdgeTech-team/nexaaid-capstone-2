"""5.1 / 4.1: the details behind the admin dashboard tiles.

GET /dashboard/admin/reports?status=  -> reports behind the report tiles
GET /dashboard/admin/held             -> held donations, grouped
                                         Report -> Entries -> Items
"""
from tests.test_role_flows import api, ok  # noqa: F401  (fixture)
from tests.test_donation_batch import _report


def _entry(client, headers, rid, n_items):
    return ok(client.post("/donations/batch", headers=headers, json={
        "report_id": rid,
        "handover_method": "Drop Off",
        "items": [{"item_id": 1, "packaging": "Box", "quantity": 2} for _ in range(n_items)],
    }), 201)


def _receive(client, t, donation_id):
    ok(client.post("/donations/receive", headers=t["csws"],
                   json={"donation_id": donation_id, "actual_quantity": 2}))


def _cmo(client, t, donation_id, status):
    ok(client.post(f"/cmo/donations/{donation_id}/confirm", headers=t["cmo"],
                   json={"status": status, "notes": "waiting for papers"}), 201)


# ------------------------------------------------------ /dashboard/admin/reports

def test_reports_drilldown_filters_by_status(api):
    client, t = api
    rid = _report(client, t)   # a validated report

    validated = ok(client.get("/dashboard/admin/reports?status=Validated", headers=t["admin"]))
    row = next(r for r in validated if r["report_id"] == rid)
    assert row["status"] == "Validated"
    assert row["report_label"].startswith(f"#{rid} ")
    assert "fulfillment_percentage" in row

    pending = ok(client.get("/dashboard/admin/reports?status=Pending", headers=t["admin"]))
    assert rid not in [r["report_id"] for r in pending]

    # The list behind the tile has as many rows as the tile's number.
    dash = ok(client.get("/dashboard/admin", headers=t["admin"]))
    assert len(validated) == dash["validated_reports"]
    assert len(pending) == dash["pending_validations"]


# --------------------------------------------------------- /dashboard/admin/held

def test_held_drilldown_groups_held_entries_and_matches_the_tile(api):
    client, t = api
    rid = _report(client, t)
    first = _entry(client, t["donor"], rid, 1)    # Donation 1: never held
    second = _entry(client, t["donor"], rid, 2)   # Donation 2: one item held
    for e in (first, second):
        for i in e["items"]:
            _receive(client, t, i["donation_id"])
    held_id = second["items"][0]["donation_id"]
    _cmo(client, t, held_id, "On Hold")

    data = ok(client.get("/dashboard/admin/held", headers=t["admin"]))
    assert data["held_donation_ids"] == [held_id]
    assert [r["report_id"] for r in data["reports"]] == [rid]
    entries = data["reports"][0]["entries"]
    assert [e["batch_reference"] for e in entries] == [second["batch_reference"]]
    # Numbered like the normal entries view: still "Donation 2", not 1.
    assert entries[0]["entry_no"] == 2
    assert len(entries[0]["items"]) == 2          # the whole entry, held item marked by id
    assert data["reports"][0]["total_entries"] == 1
    assert data["reports"][0]["total_items"] == 2

    dash = ok(client.get("/dashboard/admin", headers=t["admin"]))
    assert dash["held_donations"] == 1

    # Once the CMO confirms it, it is no longer held anywhere.
    _cmo(client, t, held_id, "Confirmed")
    assert ok(client.get("/dashboard/admin/held", headers=t["admin"])) == {
        "held_donation_ids": [], "reports": []}
    assert ok(client.get("/dashboard/admin", headers=t["admin"]))["held_donations"] == 0


def test_held_drilldown_empty_when_nothing_held(api):
    client, t = api
    assert ok(client.get("/dashboard/admin/held", headers=t["admin"])) == {
        "held_donation_ids": [], "reports": []}


# ----------------------------------------------------------------------- roles

def test_drilldowns_are_admin_only(api):
    client, t = api
    for url in ("/dashboard/admin/reports?status=Pending", "/dashboard/admin/held"):
        for role in ("csws", "cmo", "donor", "unit"):
            assert client.get(url, headers=t[role]).status_code == 403, (url, role)
        assert client.get(url).status_code == 401, url