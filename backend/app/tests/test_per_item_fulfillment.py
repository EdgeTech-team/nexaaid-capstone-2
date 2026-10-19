"""Per-item fulfillment (Oct 2026 team decision; Castillo, Module 3 / 8.4).

Before: needs were one total ("Rice 500 kg + Water 200 L" = 700) and any
delivered item counted against it, so 700 bottles of anything = 100%.
Now: one need per item in the item's base unit, each capped at 100%, the
report's percentage is the average, and priority uses option A (families
40%, severity 30%, unmet need 30%; quantity is no longer scored).

Walks the real chain with real logins: report with needs -> validate ->
donations described as packs x per pack x size -> CSWS receives -> CMO
confirms -> delivery -> barangay receipt -> per-item meters + priority.
"""
from decimal import Decimal
from types import SimpleNamespace

import pytest
from fastapi import HTTPException

from core import database
from core.priority_engine import compute_priority
from models.item_model import Item, ItemSize
from services.units import line_amounts, to_base
from tests.test_role_flows import api, ok  # noqa: F401  (fixture)

RICE, WATER = 1, 2


def _seed_items():
    db = database.SessionLocal()
    try:
        db.add(Item(item_id=WATER, item_name="Drinking Water", category="Water", unit_of_measure="L"))
        db.add(Item(item_id=3, item_name="Drinking Water (gallons, old)", category="Water",
                    unit_of_measure="gallons", active=False))
        db.flush()
        db.add_all([
            ItemSize(item_id=RICE, label="25 kg sack", amount=Decimal("25"), sort_order=1),
            ItemSize(item_id=WATER, label="500 ml bottle", amount=Decimal("0.5"), sort_order=1),
            ItemSize(item_id=WATER, label="1.5 L bottle", amount=Decimal("1.5"), sort_order=2),
        ])
        db.commit()
        return {s.label: s.size_id for s in db.query(ItemSize).all()}
    finally:
        db.close()


def _needs(client, rid, headers=None):
    return ok(client.get(f"/reports/{rid}/needs", headers=headers or {}))


def _need(progress, name):
    return next(n for n in progress["needs"] if n["item_name"] == name)


# ---------------------------------------------------------------------------
# Unit conversion
# ---------------------------------------------------------------------------
def test_sizes_convert_to_the_base_unit():
    water = SimpleNamespace(item_id=WATER, unit_of_measure="L")
    rice = SimpleNamespace(item_id=RICE, unit_of_measure="kg")
    cans = SimpleNamespace(item_id=9, unit_of_measure="cans")

    def line(**kw):
        base = dict(quantity=None, packaging=None, pack_count=None, per_pack=None,
                    size_id=None, size_amount=None, size_unit=None)
        return SimpleNamespace(**{**base, **kw})

    # 3 boxes x 16 x 1.5 L = 72 L
    got = line_amounts(None, water, line(pack_count=3, per_pack=16, size_amount=Decimal("1.5"), size_unit="L"))
    assert got["quantity"] == 72 and got["packaging"] == "Pack of 16 x 1.5 L"
    # 10 boxes x 12 x 500 ml = 60 L
    assert line_amounts(None, water, line(pack_count=10, per_pack=12, size_amount=500, size_unit="ml"))["quantity"] == 60
    # 4 x 5 gallon = 75.7 L -> 76 (rounded to a whole liter; breakdown kept)
    got = line_amounts(None, water, line(pack_count=4, size_amount=5, size_unit="gallons"))
    assert got["quantity"] == 76 and got["per_pack"] == 1
    # 4 x 25 kg = 100 kg; 3 x 500 g = 1.5 kg -> 2 kg
    assert line_amounts(None, rice, line(pack_count=4, size_amount=25, size_unit="kg"))["quantity"] == 100
    assert line_amounts(None, rice, line(pack_count=3, size_amount=500, size_unit="g"))["quantity"] == 2
    # counted items: 10 packs of 6 cans = 60 cans; no size = 1 can each
    assert line_amounts(None, cans, line(pack_count=10, per_pack=6))["quantity"] == 60
    # older apps: total + packaging kept exactly as sent
    old = line_amounts(None, rice, line(quantity=50, packaging="Sack (50 kg)"))
    assert (old["quantity"], old["packaging"], old["pack_count"]) == (50, "Sack (50 kg)", None)

    with pytest.raises(HTTPException):        # ml for rice makes no sense
        to_base(Decimal(1), "ml", "kg")
    with pytest.raises(HTTPException):        # less than 1 L in total
        line_amounts(None, water, line(pack_count=1, size_amount=250, size_unit="ml"))


# ---------------------------------------------------------------------------
# The whole chain
# ---------------------------------------------------------------------------
def test_per_item_fulfillment_through_the_whole_chain(api):
    client, t = api
    sizes = _seed_items()

    # Lookups: base unit, kind, sizes; retired items hidden.
    items = {i["item_name"]: i for i in ok(client.get("/lookups"))["items"]}
    assert "Drinking Water (gallons, old)" not in items
    assert items["Drinking Water"]["kind"] == "volume"
    assert items["Drinking Water"]["size_units"] == ["L", "ml", "gallon"]
    assert [s["label"] for s in items["Drinking Water"]["sizes"]] == ["500 ml bottle", "1.5 L bottle"]

    # --- report with per-item needs (one "Other" item) -------------------
    report = ok(client.post("/reports/", headers=t["unit"], json={
        "disaster_type_id": 1, "barangay_id": 1, "affected_families": 120,
        "needs": [
            {"item_id": RICE, "quantity": 500},
            {"item_id": WATER, "quantity": 200},
            {"other_item_name": "Diapers", "other_item_unit": "pcs", "quantity": 100},
        ],
    }), 201)
    rid = report["report_id"]
    assert [(n["item_name"], n["unit"], n["quantity"]) for n in report["needs"]] == [
        ("Rice", "kg", 500), ("Drinking Water", "L", 200), ("Diapers", "pcs", 100)]
    assert report["estimated_quantity"] == 800            # kept for older screens
    assert report["assistance_needed"] == "Rice: 500 kg, Drinking Water: 200 L, Diapers: 100 pcs"
    # the same item twice, or a retired item, is refused
    bad = {"disaster_type_id": 1, "barangay_id": 1, "affected_families": 5}
    assert client.post("/reports/", headers=t["unit"], json={
        **bad, "needs": [{"item_id": RICE, "quantity": 1}, {"item_id": RICE, "quantity": 2}]}).status_code == 422
    assert client.post("/reports/", headers=t["unit"], json={
        **bad, "needs": [{"item_id": 3, "quantity": 1}]}).status_code == 422
    # not validated yet: hidden from the public, visible to its reporter
    assert client.get(f"/reports/{rid}/needs").status_code == 404
    _needs(client, rid, t["unit"])

    validated = ok(client.post(f"/reports/{rid}/validate", headers=t["admin"], json={}))
    # option A: 120 families 100*0.4 + Flood 70*0.3 + unmet 100*0.3 = 91
    assert float(validated["ai_priority_score"]) == 91.0 and validated["priority_level"] == "Critical"
    p = _needs(client, rid)                                # public now
    assert p["fulfillment_percentage"] == 0.0 and len(p["needs"]) == 3

    # --- donations: new breakdown, older total, and an unrequested item ---
    entry = ok(client.post("/donations/batch", headers=t["donor"], json={
        "report_id": rid, "handover_method": "Drop Off",
        "items": [
            {"item_id": RICE, "pack_count": 4, "size_id": sizes["25 kg sack"]},              # 100 kg
            {"item_id": WATER, "pack_count": 3, "per_pack": 16, "size_id": sizes["1.5 L bottle"]},  # 72 L
            {"item_id": RICE, "quantity": 50, "packaging": "Sack (50 kg)"},                   # older app
            {"other_item_name": "Blanket", "other_item_unit": "pcs", "pack_count": 5},        # not needed
        ],
    }), 201)
    lines = entry["items"]
    assert [l["quantity"] for l in lines] == [100, 72, 50, 5]
    assert lines[1]["amount_text"] == "3 x 16 x 1.5 L bottle = 72 L"
    assert lines[2]["pack_count"] is None
    # a size of another item is refused
    assert client.post("/donations/batch", headers=t["donor"], json={
        "report_id": rid, "handover_method": "Drop Off",
        "items": [{"item_id": RICE, "pack_count": 1, "size_id": sizes["500 ml bottle"]}]}).status_code == 422

    p = _needs(client, rid)
    assert (_need(p, "Rice")["pledged"], _need(p, "Drinking Water")["pledged"]) == (150, 72)
    assert _need(p, "Rice")["pledged_percentage"] == 30.0
    assert [g["item_name"] for g in p["additional_goods"]] == ["Blanket"]   # never in the %

    # --- CSWS receives (2 water bottles broken: 69 L) ---------------------
    ref = entry["batch_reference"]
    ok(client.post(f"/donations/entries/{ref}/receive", headers=t["csws"], json={"items": [
        {"donation_id": lines[0]["donation_id"], "actual_quantity": 100},
        {"donation_id": lines[1]["donation_id"], "actual_quantity": 69},
        {"donation_id": lines[2]["donation_id"], "actual_quantity": 50},
        {"donation_id": lines[3]["donation_id"], "actual_quantity": 5},
    ]}))
    assert _need(_needs(client, rid), "Drinking Water")["pledged"] == 69   # counted amount wins
    assert _need(_needs(client, rid), "Rice")["confirmed"] == 0            # CMO has not acknowledged

    for line in lines[:3]:
        ok(client.post(f"/cmo/donations/{line['donation_id']}/confirm", headers=t["cmo"],
                       json={"status": "Confirmed"}), 201)
    p = _needs(client, rid)
    assert (_need(p, "Rice")["confirmed"], _need(p, "Drinking Water")["confirmed"]) == (150, 69)
    assert p["fulfillment_percentage"] == 0.0                 # nothing delivered yet

    # --- delivery + barangay receipt ---------------------------------------
    did = ok(client.post("/deliveries/", headers=t["csws"], json={
        "report_id": rid, "destination_barangay_id": 1, "delivery_date": "2026-10-20T08:00:00",
        "items": [{"item_id": RICE, "quantity": 150}, {"item_id": WATER, "quantity": 69}],
    }), 201)["delivery_id"]
    ok(client.post(f"/deliveries/{did}/advance", headers=t["csws"]))
    ok(client.post(f"/deliveries/{did}/advance", headers=t["csws"]))
    body = ok(client.post(f"/deliveries/{did}/confirm-receipt", headers=t["brgy"], json={}), 201)

    # Rice 150/500 = 30%, Water 69/200 = 34.5%, Diapers 0% -> average 21.5%
    f = body["fulfillment"]
    assert float(f["fulfillment_percentage"]) == 21.5
    assert f["verification_status"] == "Partial"
    assert (f["total_items_needed"], f["total_items_delivered"]) == (800, 219)
    p = _needs(client, rid)
    assert [n["delivered_percentage"] for n in p["needs"]] == [30.0, 34.5, 0.0]
    report = ok(client.get(f"/reports/{rid}", headers=t["admin"]))
    assert float(report["fulfillment_percentage"]) == 21.5
    # priority moved with fulfillment: 40 + 21 + Partial 50*0.3 = 76 -> High
    assert report["priority_level"] == "High"

    # Public feed and donor lookups carry the per-item lines.
    pub = next(r for r in ok(client.get("/public/reports")) if r["report_id"] == rid)
    assert [n["item_name"] for n in pub["needs"]] == ["Rice", "Drinking Water", "Diapers"]
    lk = next(r for r in ok(client.get("/lookups"))["validated_reports"] if r["id"] == rid)
    assert _need(lk, "Drinking Water")["delivered"] == 69


def test_older_apps_still_work_with_one_general_need(api):
    """A report sent the old way (estimated_quantity only) gets one "General
    needs" line that counts every item, so its percentage is what it was."""
    client, t = api
    report = ok(client.post("/reports/", headers=t["unit"], json={
        "disaster_type_id": 1, "barangay_id": 1, "affected_families": 40,
        "assistance_needed": "Rice", "estimated_quantity": 100}), 201)
    rid = report["report_id"]
    assert [(n["item_id"], n["item_name"], n["quantity"]) for n in report["needs"]] == [(None, "General needs", 100)]
    ok(client.post(f"/reports/{rid}/validate", headers=t["admin"], json={}))
    d = ok(client.post("/donations/", headers=t["donor"], json={
        "report_id": rid, "item_id": RICE, "packaging": "Box", "quantity": 60, "handover_method": "Drop Off"}))
    ok(client.post("/donations/receive", headers=t["csws"], json={"donation_id": d["donation_id"], "actual_quantity": 60}))
    ok(client.post(f"/cmo/donations/{d['donation_id']}/confirm", headers=t["cmo"], json={"status": "Confirmed"}), 201)
    did = ok(client.post("/deliveries/", headers=t["csws"], json={
        "report_id": rid, "destination_barangay_id": 1, "delivery_date": "2026-10-20T08:00:00",
        "items": [{"item_id": RICE, "quantity": 50}]}), 201)["delivery_id"]
    ok(client.post(f"/deliveries/{did}/advance", headers=t["csws"]))
    ok(client.post(f"/deliveries/{did}/advance", headers=t["csws"]))
    body = ok(client.post(f"/deliveries/{did}/confirm-receipt", headers=t["brgy"], json={}), 201)
    assert float(body["fulfillment"]["fulfillment_percentage"]) == 50.0
    assert _needs(client, rid)["needs"][0]["delivered"] == 50


def test_editing_needs_and_matching_items_at_receiving(api):
    client, t = api
    _seed_items()
    rid = ok(client.post("/reports/", headers=t["unit"], json={
        "disaster_type_id": 1, "barangay_id": 1, "affected_families": 10,
        "needs": [{"item_id": RICE, "quantity": 100}]}), 201)["report_id"]
    # the reporter corrects the needs before validation
    edited = ok(client.put(f"/reports/{rid}/mine", headers=t["unit"], json={
        "disaster_type_id": 1, "barangay_id": 1, "affected_families": 10,
        "needs": [{"item_id": RICE, "quantity": 40}, {"item_id": WATER, "quantity": 40}]}))
    assert [(n["item_name"], n["quantity"]) for n in edited["needs"]] == [("Rice", 40), ("Drinking Water", 40)]
    ok(client.post(f"/reports/{rid}/validate", headers=t["admin"], json={}))

    # A donor types "Bigas"; CSWS receives it as Rice, so it counts for Rice.
    d = ok(client.post("/donations/", headers=t["donor"], json={
        "report_id": rid, "other_item_name": "Bigas", "other_item_unit": "kg",
        "pack_count": 2, "size_amount": 10, "size_unit": "kg", "handover_method": "Drop Off"}))
    assert d["quantity"] == 20 and d["item_id"] != RICE
    ok(client.post("/donations/receive", headers=t["csws"],
                   json={"donation_id": d["donation_id"], "actual_quantity": 20, "item_id": RICE}))
    assert _need(_needs(client, rid), "Rice")["pledged"] == 20
    ok(client.post(f"/cmo/donations/{d['donation_id']}/confirm", headers=t["cmo"], json={"status": "Confirmed"}), 201)
    did = ok(client.post("/deliveries/", headers=t["csws"], json={
        "report_id": rid, "destination_barangay_id": 1, "delivery_date": "2026-10-20T08:00:00",
        "items": [{"item_id": RICE, "quantity": 20}]}), 201)["delivery_id"]
    ok(client.post(f"/deliveries/{did}/advance", headers=t["csws"]))
    ok(client.post(f"/deliveries/{did}/advance", headers=t["csws"]))
    ok(client.post(f"/deliveries/{did}/confirm-receipt", headers=t["brgy"], json={}), 201)
    # Rice 20/40 = 50%, Water 0% -> 25%
    assert ok(client.get(f"/reports/{rid}", headers=t["admin"]))["fulfillment_percentage"] in ("25.00", 25.0)

    # Weak spot 5: the admin lowers the rice need after validation; the
    # percentage and priority follow at once (Rice 20/20 = 100%, Water 0%).
    before = ok(client.get(f"/reports/{rid}", headers=t["admin"]))
    patched = ok(client.patch(f"/reports/{rid}", headers=t["admin"], json={
        "needs": [{"item_id": RICE, "quantity": 20}, {"item_id": WATER, "quantity": 40}]}))
    after = ok(client.get(f"/reports/{rid}", headers=t["admin"]))
    assert float(after["fulfillment_percentage"]) == 50.0
    assert patched["ai_processed_at"] != before["ai_processed_at"]


def test_priority_option_a_weights():
    """Quantity no longer changes priority (option A)."""
    def report(quantity):
        return SimpleNamespace(affected_families=60, estimated_quantity=quantity, assistance_needed="x",
                               disaster_type=SimpleNamespace(type_name="Typhoon"), fulfillment=None)
    small, big = compute_priority(report(1)), compute_priority(report(90_000))
    assert small["score"] == big["score"] == 75 * 0.4 + 85 * 0.3 + 100 * 0.3


def test_recompute_script_brings_old_priorities_in_line(api):
    """After the migration, reports validated under the old weights are
    listed by the dry run (nothing written) and fixed by --apply."""
    from models.report import DisasterReport
    from scripts import recompute_priorities

    client, t = api
    rid = ok(client.post("/reports/", headers=t["unit"], json={
        "disaster_type_id": 1, "barangay_id": 1, "affected_families": 120,
        "needs": [{"item_id": RICE, "quantity": 10}]}), 201)["report_id"]
    ok(client.post(f"/reports/{rid}/validate", headers=t["admin"], json={}))
    db = database.SessionLocal()
    try:
        db.get(DisasterReport, rid).priority_level = "Low"     # as if scored the old way
        db.commit()
        lines = []
        assert recompute_priorities.run(db, out=lines.append) == 0
        assert any(str(rid) in l and "Critical" in l for l in lines)
        db.expire_all()
        assert db.get(DisasterReport, rid).priority_level == "Low"          # dry run wrote nothing
        assert recompute_priorities.run(db, apply=True, as_user="testadmin@gmail.com",
                                        ask=lambda _: "APPLY", out=lines.append) == 0
        db.expire_all()
        assert db.get(DisasterReport, rid).priority_level == "Critical"
    finally:
        db.close()
