"""
5.1.3 Inventory must follow every receive (UC-CM1, Inventory module).

stock(item, report) = sum(received_goods.actual_quantity) - sum(delivery_items.quantity)

One regression test per code path that sets physical_donations.status to
Received / Confirmed or inserts received_goods:
  POST /donations/receive                 (CSWS, UC-CM1)       -> adds stock
  POST /cmo/donations/{id}/confirm        (CMO, UC-C1)          -> stock unchanged
  POST /cmo/donations/{id}/revert         (CMO, UC-C1 alt 4a)   -> stock unchanged
plus: receive is atomic, and scripts/rebuild_inventory.py.
"""
from datetime import datetime

import core.database as database
import api.v1.receiving_routes as receiving_routes
from models.delivery import Delivery, DeliveryItem
from models.inventory_model import Inventory
from models.item_model import Item
from models.physical_donation_model import PhysicalDonation
from models.received_goods_model import ReceivedGoods
from scripts import rebuild_inventory
from services.inventory import expected_stock, stock_differences
from tests.test_role_flows import api, ok  # noqa: F401  (fixture)


def _report(client, t):
    rid = ok(client.post("/reports/", headers=t["unit"], json={
        "disaster_type_id": 1, "barangay_id": 1, "estimated_quantity": 500}), 201)["report_id"]
    ok(client.post(f"/reports/{rid}/validate", headers=t["admin"], json={}))
    return rid


def _donate(client, t, rid, item_id=1, qty=100):
    return ok(client.post("/donations/", headers=t["donor"], json={
        "report_id": rid, "item_id": item_id, "packaging": "Sack (50 kg)",
        "quantity": qty, "handover_method": "Drop Off"}))["donation_id"]


def _receive(client, t, donation_id, qty):
    return ok(client.post("/donations/receive", headers=t["csws"],
                          json={"donation_id": donation_id, "actual_quantity": qty}))


def _stock(item_id, report_id):
    db = database.SessionLocal()
    try:
        row = (db.query(Inventory)
               .filter(Inventory.item_id == item_id, Inventory.report_id == report_id).first())
        return None if row is None else row.quantity
    finally:
        db.close()


def _add_item(name):
    db = database.SessionLocal()
    try:
        item = Item(item_name=name, category="Food", unit_of_measure="pcs")
        db.add(item)
        db.commit()
        return item.item_id
    finally:
        db.close()


def test_receive_adds_actual_quantity_per_item_and_report(api):
    client, t = api
    r1, r2 = _report(client, t), _report(client, t)
    water = _add_item("Water")
    # The reported case: two items of one entry, actual less than declared.
    a, b = _donate(client, t, r1, 1, 100), _donate(client, t, r1, water, 20)
    _receive(client, t, a, 100)
    _receive(client, t, b, 15)                       # UC-CM1 alt 4a: less than declared
    assert _stock(1, r1) == 100 and _stock(water, r1) == 15
    # Same item, same report: added to the same row.
    _receive(client, t, _donate(client, t, r1, 1, 70), 70)
    assert _stock(1, r1) == 170
    # Same item, another report: its own row.
    _receive(client, t, _donate(client, t, r2, 1, 5), 5)
    assert _stock(1, r2) == 5 and _stock(1, r1) == 170
    inv = ok(client.get("/donations/inventory", headers=t["csws"]))
    assert {(i["item_id"], i["report_id"], i["quantity"]) for i in inv} == {
        (1, r1, 170), (water, r1, 15), (1, r2, 5)}


def test_receive_is_atomic(api, monkeypatch):
    """If adding to inventory fails, the receipt and the status change are
    rolled back too, so a donation can never be Received without stock."""
    client, t = api
    rid = _report(client, t)
    d = _donate(client, t, rid)

    def boom(*a, **k):
        raise RuntimeError("inventory write failed")
    monkeypatch.setattr(receiving_routes, "add_received_stock", boom)
    r = client.post("/donations/receive", headers=t["csws"],
                    json={"donation_id": d, "actual_quantity": 100})
    assert r.status_code == 500

    db = database.SessionLocal()
    try:
        assert db.get(PhysicalDonation, d).status == "Pending"
        assert db.query(ReceivedGoods).filter(ReceivedGoods.donation_id == d).count() == 0
    finally:
        db.close()
    assert _stock(1, rid) is None


def test_confirm_paths_do_not_change_stock(api):
    client, t = api
    rid = _report(client, t)
    a, b = _donate(client, t, rid, qty=100), _donate(client, t, rid, qty=70)
    _receive(client, t, a, 100)
    _receive(client, t, b, 70)
    assert _stock(1, rid) == 170

    ok(client.post(f"/cmo/donations/{a}/confirm", headers=t["cmo"],
                   json={"status": "Confirmed"}), 201)                               # CMO confirm
    assert _stock(1, rid) == 170
    ok(client.post(f"/cmo/donations/{b}/confirm", headers=t["cmo"],
                   json={"status": "On Hold", "notes": "check"}), 201)              # CMO hold
    ok(client.post(f"/cmo/donations/{b}/confirm", headers=t["cmo"],
                   json={"status": "Confirmed"}), 201)                               # CMO confirm
    assert _stock(1, rid) == 170
    ok(client.post(f"/cmo/donations/{b}/revert", headers=t["cmo"]))                  # CMO revert
    assert _stock(1, rid) == 170

    db = database.SessionLocal()
    try:
        assert stock_differences(db) == []
    finally:
        db.close()


def test_deliveries_subtract_and_formula_matches(api):
    client, t = api
    rid = _report(client, t)
    _receive(client, t, _donate(client, t, rid, qty=100), 100)
    ok(client.post("/deliveries/", headers=t["csws"], json={
        "report_id": rid, "destination_barangay_id": 1, "delivery_date": "2026-10-06T08:00:00",
        "items": [{"item_id": 1, "quantity": 30}]}), 201)
    assert _stock(1, rid) == 70
    db = database.SessionLocal()
    try:
        assert expected_stock(db)[(1, rid)] == 70
        assert stock_differences(db) == []
    finally:
        db.close()


# ----------------------------------------------- scripts/rebuild_inventory.py

def _break_inventory(client, t):
    """Reproduce the shared-DB state: Received / Confirmed donations whose
    inventory rows are missing or wrong."""
    rid = _report(client, t)
    water = _add_item("Water")
    a, b = _donate(client, t, rid, 1, 100), _donate(client, t, rid, water, 20)
    _receive(client, t, a, 100)
    _receive(client, t, b, 15)
    ok(client.post(f"/cmo/donations/{a}/confirm", headers=t["cmo"],
                   json={"status": "Confirmed"}), 201)
    db = database.SessionLocal()
    try:
        db.query(Inventory).filter(Inventory.item_id == water).delete()   # missing row
        db.query(Inventory).filter(Inventory.item_id == 1).update({"quantity": 7})  # wrong qty
        db.commit()
    finally:
        db.close()
    return rid, water


def test_script_dry_run_reports_and_writes_nothing(api):
    client, t = api
    rid, water = _break_inventory(client, t)
    lines = []
    db = database.SessionLocal()
    try:
        assert rebuild_inventory.run(db, apply=False, out=lines.append) == 0
        db.rollback()
    finally:
        db.close()
    text = "\n".join(lines)
    assert "2 inventory row(s) differ" in text and "missing" in text and "Dry run" in text
    assert _stock(1, rid) == 7 and _stock(water, rid) is None        # unchanged


def test_script_apply_needs_admin_and_typed_confirmation(api):
    client, t = api
    rid, water = _break_inventory(client, t)

    def run(**kw):
        db = database.SessionLocal()
        try:
            return rebuild_inventory.run(db, apply=True, out=lambda *_: None, **kw)
        finally:
            db.close()

    assert run(as_user=None, ask=lambda _: "APPLY") == 2                      # no admin given
    assert run(as_user="csws.test@example.com", ask=lambda _: "APPLY") == 2   # not an admin
    assert run(as_user="testadmin@gmail.com", ask=lambda _: "yes") == 1       # not typed APPLY
    assert _stock(1, rid) == 7 and _stock(water, rid) is None

    assert run(as_user="testadmin@gmail.com", ask=lambda _: "APPLY") == 0
    assert _stock(1, rid) == 100 and _stock(water, rid) == 15
    db = database.SessionLocal()
    try:
        assert stock_differences(db) == []                                      # idempotent
    finally:
        db.close()
    logs = ok(client.get("/admin/audit-logs?entity_type=inventory", headers=t["admin"]))
    assert logs[0]["action"] == "REBUILD INVENTORY" and len(logs[0]["new_value"]["rows"]) == 2


def test_script_skips_rows_that_would_go_negative(api):
    client, t = api
    rid = _report(client, t)
    _receive(client, t, _donate(client, t, rid, qty=10), 10)
    db = database.SessionLocal()
    try:   # a delivery larger than what was received (bad old data)
        d = Delivery(report_id=rid, destination_barangay_id=1, handled_by_user_id=1,
                     status="Preparing", delivery_date=datetime(2026, 10, 6, 8, 0))
        db.add(d)
        db.flush()
        db.add(DeliveryItem(delivery_id=d.delivery_id, item_id=1, quantity=25))
        db.commit()
    finally:
        db.close()
    lines = []
    db = database.SessionLocal()
    try:
        rebuild_inventory.run(db, apply=True, as_user="testadmin@gmail.com",
                              ask=lambda _: "APPLY", out=lines.append)
    finally:
        db.close()
    assert any("below zero" in l for l in lines)
    assert _stock(1, rid) == 10                                                 # left alone
