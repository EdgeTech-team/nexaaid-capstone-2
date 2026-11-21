"""Nov 21, 2026 batch of fixes (one branch from copy-develop):

- Disaster reports: quantities and families are whole numbers; decimals
  that look whole (0.0, 5.0) are refused too (item 5).
- Item clean-up: "Bigas" is Rice, "Diapar" is Diaper, "MC Water" is gone
  (item 4): the migration and the typed-name aliases.
- Registration review: the Administrator deletes a donor or organization
  account in one step with a required reason (item 2).
- "Needs your action": only the CMO Representative keeps it (Nov 22).
- Inventory: rows at 0 are not listed (item 7).
"""
import importlib.util
from pathlib import Path

import sqlalchemy as sa
from sqlalchemy import create_engine
from sqlalchemy.pool import StaticPool

from core import database
from core.database import Base
from core.notifications import render_event
from models.audit_log_model import AuditLog
from models.inventory_model import Inventory
from models.item_model import Item
from models.physical_donation_model import PhysicalDonation
from models.user_rbac_model import User
from tests.reg_helpers import donor_payload
from tests.test_role_flows import api, ok  # noqa: F401  (fixture)


def _validated_report(client, t):
    rid = ok(client.post("/reports/", headers=t["unit"], json={
        "disaster_type_id": 1, "barangay_id": 1, "estimated_quantity": 500}), 201)["report_id"]
    ok(client.post(f"/reports/{rid}/validate", headers=t["admin"], json={}))
    return rid


def _uid(client, t, email):
    return next(u["user_id"] for u in ok(client.get("/admin/users", headers=t["admin"]))
                if u["email"] == email)


# ---------------------------------------------------------------------------
# Item 5: whole numbers only
# ---------------------------------------------------------------------------

def test_report_quantities_refuse_decimals(api):
    client, t = api
    base = {"disaster_type_id": 1, "barangay_id": 1, "affected_families": 10}
    for bad in (5.0, 0.0, 2.5, "5.0"):
        r = client.post("/reports/", headers=t["unit"],
                        json={**base, "needs": [{"item_id": 1, "quantity": bad}]})
        assert r.status_code == 422, (bad, r.text)
    r = client.post("/reports/", headers=t["unit"], json={**base, "affected_families": 10.0})
    assert r.status_code == 422
    ok(client.post("/reports/", headers=t["unit"],
                   json={**base, "needs": [{"item_id": 1, "quantity": 5}]}), 201)


def test_multi_barangay_report_refuses_decimals(api):
    client, t = api
    body = {"disaster_type_id": 1, "description": "Earthquake", "barangays": [
        {"barangay_id": 1, "affected_families": 10, "needs": [{"item_id": 1, "quantity": 60}]},
        {"barangay_id": 2, "affected_families": 5, "needs": [{"item_id": 1, "quantity": 30.0}]},
    ]}
    assert client.post("/reports/batch", headers=t["unit"], json=body).status_code == 422
    body["barangays"][1]["needs"][0]["quantity"] = 30
    body["barangays"][1]["affected_families"] = 5.0
    assert client.post("/reports/batch", headers=t["unit"], json=body).status_code == 422


# ---------------------------------------------------------------------------
# Item 4: typed names of cleaned-up items
# ---------------------------------------------------------------------------

def test_typed_bigas_is_rice_and_mc_water_is_refused(api):
    client, t = api
    rid = _validated_report(client, t)
    base = {"report_id": rid, "handover_method": "Drop Off"}
    entry = ok(client.post("/donations/batch", headers=t["donor"], json={**base, "items": [
        {"other_item_name": "Bigas", "other_item_unit": "kg", "quantity": 5, "packaging": "Pack"}]}), 201)
    assert [i["item_id"] for i in entry["items"]] == [1]   # Rice, not a new item

    r = client.post("/donations/batch", headers=t["donor"], json={**base, "items": [
        {"other_item_name": "MC Water", "other_item_unit": "L", "quantity": 5, "packaging": "Pack"}]})
    assert r.status_code == 422 and "no longer offered" in r.json()["detail"]

    ok(client.post("/donations/batch", headers=t["donor"], json={**base, "items": [
        {"other_item_name": "diapar", "other_item_unit": "pcs", "quantity": 5, "packaging": "Pack"}]}), 201)
    db = database.SessionLocal()
    try:
        names = {i.item_name for i in db.query(Item).all()}
        assert "Diaper" in names and not {"diapar", "Diapar", "Bigas"} & names
    finally:
        db.close()


def test_dropdowns_leave_out_bigas_and_mc_water(api):
    """Before the clean-up migration runs: Bigas (Rice is listed) and MC
    Water are not offered; a typo with no item to point to stays."""
    client, t = api
    db = database.SessionLocal()
    try:
        db.add_all([Item(item_name=n, category="Other", unit_of_measure=u)
                    for n, u in (("Bigas", "kg"), ("Bigas (sacks)", "sacks"),
                                 ("MC Water", "L"), ("Diapar", "pcs"))])
        db.commit()
    finally:
        db.close()
    names = {i["item_name"] for i in ok(client.get("/lookups", headers=t["donor"]))["items"]}
    assert "Rice" in names and "Diapar" in names
    assert not {"Bigas", "Bigas (sacks)", "MC Water"} & names

    # The live catalog spells it "Diapers": "diapar" is hidden next to it,
    # and a typed "diapar" is that item.
    db = database.SessionLocal()
    try:
        diapers = Item(item_name="Diapers", category="Hygiene", unit_of_measure="pcs")
        db.add(diapers)
        db.commit()
        diapers_id = diapers.item_id
    finally:
        db.close()
    items = ok(client.get("/lookups", headers=t["donor"]))["items"]
    names = {i["item_name"] for i in items}
    assert "Diapers" in names and "Diapar" not in names
    rid = _validated_report(client, t)
    entry = ok(client.post("/donations/batch", headers=t["donor"], json={
        "report_id": rid, "handover_method": "Drop Off", "items": [
            {"other_item_name": "diapar", "other_item_unit": "pcs", "quantity": 5,
             "packaging": "Pack"}]}), 201)
    assert [i["item_id"] for i in entry["items"]] == [diapers_id]


def _migration():
    path = next(Path(__file__).resolve().parents[1].glob(
        "alembic/versions/f3b8d1c5a9e7_*.py"))
    spec = importlib.util.spec_from_file_location("item_cleanup_migration", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_item_cleanup_migration_merges_renames_and_retires():
    engine = create_engine("sqlite:///:memory:", poolclass=StaticPool,
                           connect_args={"check_same_thread": False})
    Base.metadata.create_all(engine)
    m = _migration()
    with engine.begin() as bind:
        bind.execute(sa.text(
            "INSERT INTO items (item_id, item_name, category, unit_of_measure, active, pending_review) VALUES "
            "(1, 'Rice', 'Food', 'kg', 1, 0), (2, 'Bigas', 'Other', 'kg', 1, 0), "
            "(3, 'Bigas (sacks)', 'Other', 'sacks', 1, 0), (4, 'Diapar', 'Other', 'pcs', 1, 0), "
            "(5, 'MC Water', 'Water', 'L', 0, 0), (6, 'MC Water (L)', 'Other', 'L', 1, 0)"))
        bind.execute(sa.text(
            "INSERT INTO report_needs (report_id, item_id, quantity) VALUES "
            "(1, 1, 10), (1, 2, 5), (2, 2, 7), (3, 6, 4)"))
        bind.execute(sa.text(
            "INSERT INTO inventory (item_id, report_id, quantity) VALUES (1, 1, 4), (2, 1, 3), (6, 3, 9)"))

        m._fold_into(bind, "Bigas", "Rice", rename_when_missing=False)
        m._fold_into(bind, "Diapar", "Diaper", rename_when_missing=True)
        for src in m._items_named(bind, "MC Water"):
            bind.execute(sa.text("DELETE FROM report_needs WHERE item_id = :i"), {"i": src.item_id})
            if m._used(bind, src.item_id):
                m._retire(bind, src, "used")
            else:
                bind.execute(sa.text("DELETE FROM items WHERE item_id = :i"), {"i": src.item_id})

        items = {r.item_id: (r.item_name, bool(r.active)) for r in bind.execute(
            sa.text("SELECT item_id, item_name, active FROM items"))}
        needs = sorted(tuple(r) for r in bind.execute(
            sa.text("SELECT report_id, item_id, quantity FROM report_needs")))
        stock = sorted(tuple(r) for r in bind.execute(
            sa.text("SELECT item_id, report_id, quantity FROM inventory")))

    assert 2 not in items                                   # Bigas (kg) merged into Rice
    assert items[3] == ("Bigas (sacks)", False)             # other unit: retired, kept
    assert items[4] == ("Diaper", True)                     # typo fixed
    assert 5 not in items                                   # unused MC Water deleted
    assert items[6] == ("MC Water (L)", False)              # in stock: retired, kept
    assert needs == [(1, 1, 15), (2, 1, 7)]                 # quantities added up
    assert stock == [(1, 1, 7), (6, 3, 9)]


# ---------------------------------------------------------------------------
# Item 2: delete a registration with a reason
# ---------------------------------------------------------------------------

def test_admin_deletes_a_registration_with_a_reason(api, sent_emails):
    client, t = api
    email = "fake.id@example.com"
    ok(client.post("/auth/register/donor", json=donor_payload(client, email)), 201)
    uid = _uid(client, t, email)

    assert client.post(f"/admin/users/{uid}/delete", headers=t["donor"],
                       json={"reason": "Fake ID"}).status_code == 403
    assert client.post(f"/admin/users/{uid}/delete", headers=t["admin"],
                       json={"reason": "  "}).status_code == 422
    assert client.post(f"/admin/users/{uid}/delete", headers=t["admin"],
                       json={}).status_code == 422
    csws = _uid(client, t, "csws.test@example.com")
    assert client.post(f"/admin/users/{csws}/delete", headers=t["admin"],
                       json={"reason": "Fake ID"}).status_code == 400   # staff: two steps

    # One step, even while active: the account signed in right away.
    r = ok(client.post(f"/admin/users/{uid}/delete", headers=t["admin"],
                       json={"reason": "Fake ID"}))
    assert r == {"user_id": uid, "deleted": True, "reason": "Fake ID"}
    assert client.post(f"/admin/users/{uid}/delete", headers=t["admin"],
                       json={"reason": "Fake ID"}).status_code == 404

    db = database.SessionLocal()
    try:
        row = db.get(User, uid)
        assert row.deleted_at is not None and not row.is_active
        log = db.query(AuditLog).filter(AuditLog.action == "DELETE ACCOUNT").one()
        assert log.new_value["reason"] == "Fake ID"
    finally:
        db.close()
    removed = [m for m in sent_emails if m["to"] == email and "removed" in m["subject"]]
    assert removed and "Reason: Fake ID" in removed[0]["body"]


def test_registration_notification_reminds_to_check_the_id():
    _, donor = render_event("donor_registered", name="Maria Cruz")
    assert donor.startswith("Maria Cruz registered as an individual donor.")
    assert "valid ID" in donor and "Delete the account with a reason" in donor
    _, org = render_event("org_registered", name="Helping Hands")
    assert "contact person's valid ID" in org and "supporting document" in org
    assert "Invalid document" in org


# ---------------------------------------------------------------------------
# Item 6 / Nov 22: "Needs your action" only for the CMO Representative
# ---------------------------------------------------------------------------

def test_needs_action_is_for_the_cmo_only(api):
    client, t = api
    rid = _validated_report(client, t)
    ok(client.post("/donations/batch", headers=t["donor"], json={
        "report_id": rid, "handover_method": "Drop Off",
        "items": [{"item_id": 1, "quantity": 5, "packaging": "Sack"},
                  {"other_item_name": "Soap", "quantity": 2, "packaging": "Pack"}]}), 201)
    ok(client.post("/reports/", headers=t["unit"], json={
        "disaster_type_id": 1, "barangay_id": 1, "estimated_quantity": 10}), 201)
    empty = {"items": [], "all_caught_up": True}
    assert ok(client.get("/dashboard/needs-action", headers=t["cmo"])) == empty

    db = database.SessionLocal()
    try:   # the goods arrive at CSWS: Received, waiting for the CMO
        for d in db.query(PhysicalDonation).all():
            d.status = "Received"
        db.commit()
    finally:
        db.close()
    cmo = ok(client.get("/dashboard/needs-action", headers=t["cmo"]))["items"]
    assert [(i["key"], i["count"], i["view"]) for i in cmo] == [("acknowledge", 1, "Acknowledge")]
    # Every other role: removed (the app no longer shows it either).
    for who in ("admin", "unit", "brgy", "donor", "csws"):
        assert ok(client.get("/dashboard/needs-action", headers=t[who])) == empty, who


# ---------------------------------------------------------------------------
# Item 7: stock at 0 is not listed
# ---------------------------------------------------------------------------

def test_inventory_lists_only_items_in_stock(api):
    client, t = api
    rid = _validated_report(client, t)
    db = database.SessionLocal()
    try:
        soap = Item(item_name="Soap", category="Hygiene", unit_of_measure="pcs")
        db.add(soap)
        db.flush()
        db.add_all([Inventory(item_id=1, report_id=rid, quantity=0),
                    Inventory(item_id=soap.item_id, report_id=rid, quantity=12)])
        db.commit()
    finally:
        db.close()
    rows = ok(client.get("/donations/inventory", headers=t["csws"]))
    assert [(r["item_name"], r["quantity"]) for r in rows] == [("Soap", 12)]
    summary = ok(client.get("/dashboard/csws-main", headers=t["csws"]))["inventory_summary"]
    assert [(r["item"], r["quantity"]) for r in summary] == [("Soap", 12)]


# ---------------------------------------------------------------------------
# Nov 22: what is inside a kit (a note only)
# ---------------------------------------------------------------------------

def test_kit_contents_are_a_note_that_never_changes_the_item(api):
    client, t = api
    rid = _validated_report(client, t)
    entry = ok(client.post("/donations/batch", headers=t["donor"], json={
        "report_id": rid, "handover_method": "Drop Off", "items": [
            {"item_id": 1, "quantity": 5, "packaging": "Pack",
             "contents": "  Spoon,   Fork, Plate "},
            {"item_id": 1, "quantity": 2, "packaging": "Sack", "contents": "   "}]}), 201)
    ref = entry["batch_reference"]
    lines = entry["items"]
    assert [(i["item_id"], i["quantity"], i["contents"]) for i in lines] == [
        (1, 5, "Spoon, Fork, Plate"), (1, 2, None)]
    db = database.SessionLocal()
    try:
        rows = db.query(PhysicalDonation).filter(PhysicalDonation.batch_reference == ref).all()
        assert sorted((r.item_id, r.quantity) for r in rows) == [(1, 2), (1, 5)]
    finally:
        db.close()
    assert client.post("/donations/batch", headers=t["donor"], json={
        "report_id": rid, "handover_method": "Drop Off", "items": [
            {"item_id": 1, "quantity": 5, "packaging": "Pack", "contents": "x" * 301}]}
    ).status_code == 422


def test_kitchen_kits_fold_into_one_kitchen_set(api):
    """Nov 22: one kitchen item. "kitchen kits" is hidden next to Kitchen
    Set, a typed "Kitchen kit" is Kitchen Set, and the migration merges it."""
    client, t = api
    db = database.SessionLocal()
    try:
        kit = Item(item_name="Kitchen Set", category="Kitchen", unit_of_measure="sets")
        dup = Item(item_name="kitchen kits", category="Other", unit_of_measure="sets")
        db.add_all([kit, dup])
        db.commit()
        kit_id = kit.item_id
    finally:
        db.close()
    names = {i["item_name"] for i in ok(client.get("/lookups", headers=t["donor"]))["items"]}
    assert "Kitchen Set" in names and "kitchen kits" not in names
    rid = _validated_report(client, t)
    entry = ok(client.post("/donations/batch", headers=t["donor"], json={
        "report_id": rid, "handover_method": "Drop Off", "items": [
            {"other_item_name": "Kitchen kit", "other_item_unit": "sets",
             "quantity": 2, "packaging": "Box"}]}), 201)
    assert [i["item_id"] for i in entry["items"]] == [kit_id]

    path = next(Path(__file__).resolve().parents[1].glob("alembic/versions/b4d8f2a6c0e3_*.py"))
    spec = importlib.util.spec_from_file_location("kitchen_merge", path)
    mig = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mig)
    engine = create_engine("sqlite:///:memory:", poolclass=StaticPool,
                           connect_args={"check_same_thread": False})
    Base.metadata.create_all(engine)
    cleanup = mig._cleanup()
    with engine.begin() as bind:
        bind.execute(sa.text(
            "INSERT INTO items (item_id, item_name, category, unit_of_measure, active, pending_review) "
            "VALUES (42, 'kitchen kits', 'Other', 'sets', 1, 0), (45, 'Kitchen Set', 'Kitchen', 'sets', 1, 0)"))
        bind.execute(sa.text(
            "INSERT INTO report_needs (report_id, item_id, quantity) VALUES (1, 42, 3), (1, 45, 5), (2, 42, 4)"))
        for name in mig.KITCHEN_NAMES:
            cleanup._fold_into(bind, name, "Kitchen Set", rename_when_missing=True)
        items = {r.item_id: r.item_name for r in bind.execute(sa.text("SELECT item_id, item_name FROM items"))}
        needs = sorted(tuple(r) for r in bind.execute(
            sa.text("SELECT report_id, item_id, quantity FROM report_needs")))
    assert items == {45: "Kitchen Set"}
    assert needs == [(1, 45, 8), (2, 45, 4)]


def test_clothing_is_one_item_again():
    """Nov 22: Upper and Lower counted clothing twice in the priority score.
    The migration makes one Clothing item; per report the amounts add up."""
    path = next(Path(__file__).resolve().parents[1].glob("alembic/versions/c6e0a4b8d2f5_*.py"))
    spec = importlib.util.spec_from_file_location("one_clothing", path)
    mig = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mig)
    engine = create_engine("sqlite:///:memory:", poolclass=StaticPool,
                           connect_args={"check_same_thread": False})
    Base.metadata.create_all(engine)
    cleanup = mig._cleanup()
    with engine.begin() as bind:
        bind.execute(sa.text(
            "INSERT INTO items (item_id, item_name, category, unit_of_measure, active, pending_review) VALUES "
            "(10, 'Clothing (packs, old)', 'Clothing', 'packs', 0, 0), "
            "(43, 'Clothing – Upper', 'Clothing', 'pcs', 1, 0), "
            "(44, 'Clothing – Lower', 'Clothing', 'pcs', 1, 0)"))
        bind.execute(sa.text(
            "INSERT INTO report_needs (report_id, item_id, quantity) VALUES "
            "(1, 43, 10), (1, 44, 10), (2, 44, 7), (3, 10, 2)"))
        bind.execute(sa.text("INSERT INTO inventory (item_id, report_id, quantity) VALUES (44, 1, 5)"))
        for name in mig.CLOTHING_NAMES:
            cleanup._fold_into(bind, name, "Clothing", rename_when_missing=True)
        items = {r.item_id: (r.item_name, bool(r.active)) for r in bind.execute(
            sa.text("SELECT item_id, item_name, active FROM items"))}
        needs = sorted(tuple(r) for r in bind.execute(
            sa.text("SELECT report_id, item_id, quantity FROM report_needs")))
        stock = [tuple(r) for r in bind.execute(sa.text("SELECT item_id, quantity FROM inventory"))]
    assert items == {10: ("Clothing (packs, old)", False), 43: ("Clothing", True)}
    assert needs == [(1, 43, 20), (2, 43, 7), (3, 10, 2)]
    assert stock == [(43, 5)]


def test_templates_suggest_one_clothing_item():
    from services.need_templates import NEED_TEMPLATES, item_per_family
    flood = NEED_TEMPLATES["Flood"]
    assert flood["Clothing"] == 2 and not any("Upper" in k or "Lower" in k for k in flood)
    assert NEED_TEMPLATES["Fire"]["Clothing"] == 4
    assert item_per_family("clothing") == 2
