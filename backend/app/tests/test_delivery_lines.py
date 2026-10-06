"""5.1.4 Prepare goods for distribution: one delivery can carry several item
lines, each any item with stock in that report's inventory (not only the
items of one donation entry). Stock checks are the existing ones."""
from tests.test_inventory_paths import _add_item, _donate, _receive, _report, _stock
from tests.test_role_flows import api, ok  # noqa: F401  (fixture)


def _deliver(client, t, rid, items):
    return client.post("/deliveries/", headers=t["csws"], json={
        "report_id": rid, "destination_barangay_id": 1,
        "delivery_date": "2026-10-06T08:00:00", "items": items})


def test_delivery_with_items_from_different_entries(api):
    client, t = api
    rid = _report(client, t)
    water = _add_item("Water")
    _receive(client, t, _donate(client, t, rid, 1, 100), 100)       # entry A: rice
    _receive(client, t, _donate(client, t, rid, water, 40), 40)     # entry B: water

    d = ok(_deliver(client, t, rid, [{"item_id": 1, "quantity": 30},
                                     {"item_id": water, "quantity": 40}]), 201)
    assert sorted((i["item_id"], i["quantity"]) for i in d["items"]) == [(1, 30), (water, 40)]
    assert _stock(1, rid) == 70 and _stock(water, rid) == 0


def test_delivery_lines_keep_stock_checks(api):
    client, t = api
    rid, other = _report(client, t), _report(client, t)
    water = _add_item("Water")
    _receive(client, t, _donate(client, t, rid, 1, 50), 50)
    _receive(client, t, _donate(client, t, other, water, 40), 40)   # stock of another report

    assert _deliver(client, t, rid, [{"item_id": 1, "quantity": 10},
                                     {"item_id": water, "quantity": 1}]).status_code == 409
    assert _deliver(client, t, rid, [{"item_id": 1, "quantity": 30},
                                     {"item_id": 1, "quantity": 30}]).status_code == 409
    assert _stock(1, rid) == 50 and _stock(water, other) == 40       # nothing taken
