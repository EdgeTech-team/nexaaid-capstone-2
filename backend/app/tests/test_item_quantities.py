"""G-002 (D8, agreement A7): packaging and quantities wherever a donated
item appears: the readable amount ("10 packs x 5 kg"), the packaging, and
the quantities that exist (declared by the donor, counted by CSWS, received
by the barangay once J1 adds it)."""
from types import SimpleNamespace

from services.item_quantities import (
    delivered_item_fields, donated_item_fields, goods_line, quantity_summary, readable_amount,
)
from tests.test_donation_batch import _report
from tests.test_pickup_contact_check import _check
from tests.test_pickup_days_and_runs import _door, _next
from tests.test_role_flows import api, ok  # noqa: F401  (fixture)

# 10 packs x 5 kg (the app sends a custom size of 5 kg per pack)
PACKS = {"item_id": 1, "pack_count": 10, "per_pack": 1, "size_amount": 5, "size_unit": "kg",
         "packaging": "Sack"}
FIELDS = ("packaging", "amount_text", "declared_quantity", "counted_quantity",
          "barangay_received_quantity", "quantity_summary")


def _row(**kw):
    base = dict(quantity=50, packaging="Sack", pack_count=None, per_pack=None, size_label=None)
    return SimpleNamespace(**{**base, **kw})


def test_readable_amount_and_summary():
    assert readable_amount(_row(pack_count=10, per_pack=1, size_label="5 kg"), "kg") == "10 packs x 5 kg"
    assert readable_amount(_row(pack_count=3, per_pack=16, size_label="1.5 L bottle", quantity=72),
                           "L") == "3 packs x 16 x 1.5 L bottle"
    assert readable_amount(_row(pack_count=1, per_pack=1, size_label="25 kg sack"), "kg") == "1 pack x 25 kg sack"
    assert readable_amount(_row(), "kg") == "50 kg"                    # older donations
    assert quantity_summary("kg", 50) == "Declared 50 kg"
    assert quantity_summary("kg", 50, 48, 47) == (
        "Declared 50 kg · Counted 48 kg · Received by barangay 47 kg")
    f = donated_item_fields(_row(), "kg", counted=48)
    assert f["declared_quantity"] == 50 and f["counted_quantity"] == 48
    assert f["barangay_received_quantity"] is None                     # until J1
    assert goods_line(_row(pack_count=10, per_pack=1, size_label="5 kg"), "Rice", "kg") == (
        "Rice: 10 packs x 5 kg (Sack)")
    d = delivered_item_fields(30, "kg")
    assert d["amount_text"] == "30 kg" and d["barangay_received_quantity"] is None


def _has_fields(item):
    missing = [k for k in FIELDS if k not in item]
    assert not missing, (missing, item)


def test_donor_and_csws_views_show_packaging_and_every_quantity(api):
    client, t = api
    rid = _report(client, t)
    b = ok(client.post("/donations/batch", headers=t["donor"], json={
        "report_id": rid, "handover_method": "Drop Off", "items": [PACKS]}), 201)
    item = b["items"][0]
    _has_fields(item)
    # The receipt keeps its per-item format, with the total.
    assert item["amount_text"] == "10 x 5 kg = 50 kg" and item["packaging"] == "Sack"
    assert item["declared_quantity"] == 50 and item["counted_quantity"] is None

    ok(client.post("/donations/receive", headers=t["csws"],
                   json={"donation_id": item["donation_id"], "actual_quantity": 48}))
    # CSWS scan, CSWS records, receive queue, the donor's My giving
    scanned = ok(client.get(f"/donations/by-batch/{b['batch_reference']}", headers=t["csws"]))
    mine = ok(client.get("/donations/mine/entries", headers=t["donor"]))
    records = ok(client.get("/donations/records?limit=20&include_closed=true", headers=t["csws"]))
    assert mine[0]["items"][0]["amount_text"] == "10 packs x 5 kg"
    for view in (scanned["items"][0], mine[0]["items"][0], records[0]["items"][0]):
        _has_fields(view)
        assert view["counted_quantity"] == 48
        assert view["quantity_summary"] == "Declared 50 kg · Counted 48 kg"
    one = ok(client.get(f"/donations/mine", headers=t["donor"]))["donations"][0]
    _has_fields(one)
    by_qr = ok(client.get(f"/donations/by-qr/{item['qr_reference']}", headers=t["csws"]))
    assert by_qr["amount_text"] == "10 packs x 5 kg" and by_qr["counted_quantity"] == 48


def test_pickup_map_and_drrmo_run_show_the_packaging(api):
    client, t = api
    rid = _report(client, t)
    ref = ok(client.post("/donations/batch", headers=t["donor"],
                         json=_door(rid, [3], items=[PACKS])), 201)["batch_reference"]
    board = ok(client.get("/donations/pickups", headers=t["csws"]))
    assert next(b for b in board if b["batch_reference"] == ref)["items_summary"] == [
        "Rice: 10 packs x 5 kg (Sack)"]
    plan = ok(client.get("/donations/pickup-plan", headers=t["csws"]))
    stop_item = next(d for s in plan["stops"] for d in s["donations"]
                     if d["batch_reference"] == ref)["items"][0]
    assert stop_item["amount_text"] == "10 packs x 5 kg" and stop_item["packaging"] == "Sack"

    ok(_check(client, t, ref, "Reached"))
    run = ok(client.post("/logistics/pickup-requests", headers=t["csws"], json={
        "pickup_date": _next(3).isoformat(), "batch_references": [ref], "trucks": 1}), 201)
    seen = next(r for r in ok(client.get("/drrmo/requests", headers=t["drrmo"]))
                if r["request_id"] == run["request_id"])
    assert seen["goods"] == ["Rice: 10 packs x 5 kg (Sack)"]


def test_cmo_rows_show_declared_and_counted(api):
    client, t = api
    rid = _report(client, t)
    b = ok(client.post("/donations/batch", headers=t["donor"], json={
        "report_id": rid, "handover_method": "Drop Off", "items": [PACKS]}), 201)
    ok(client.post("/donations/receive", headers=t["csws"],
                   json={"donation_id": b["items"][0]["donation_id"], "actual_quantity": 50}))
    rows = ok(client.get("/cmo/donations/pending", headers=t["cmo"]))
    row = next(r for r in rows if r["donation_id"] == b["items"][0]["donation_id"])
    _has_fields(row)
    assert row["amount_text"] == "10 packs x 5 kg" and row["counted_quantity"] == 50
