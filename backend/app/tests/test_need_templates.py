"""Module 3 (Oct 2026): suggested needs per disaster type, sent by /lookups."""
from core import database
from models.item_model import Item
from models.report import DisasterType
from tests.test_role_flows import api, ok  # noqa: F401  (fixture)


def test_lookups_send_the_template_of_each_disaster_type(api):
    client, _ = api
    db = database.SessionLocal()
    try:
        if not db.get(DisasterType, 1):
            db.add(DisasterType(disaster_type_id=1, type_name="Flood"))
        db.add(DisasterType(disaster_type_id=90, type_name="Not in any template"))
        known = {i.item_name for i in db.query(Item).all()}
        for name, unit in [("Rice", "kg"), ("Drinking Water", "L"), ("Hygiene Kit", "kits"),
                           ("Medicine Kit", "boxes")]:
            if name not in known:
                db.add(Item(item_name=name, category="Relief", unit_of_measure=unit))
        # A retired item is never suggested.
        db.add(Item(item_name="Blanket", category="Shelter", unit_of_measure="pcs", active=False))
        db.commit()
        flood_id = db.query(DisasterType).filter_by(type_name="Flood").one().disaster_type_id
    finally:
        db.close()

    templates = {t["name"]: t for t in ok(client.get("/lookups"))["need_templates"]}
    assert "Not in any template" not in templates
    flood = {line["item_name"]: line for line in templates["Flood"]["items"]}
    assert templates["Flood"]["id"] == flood_id
    assert flood["Rice"]["per_family"] == 6 and flood["Rice"]["unit"] == "kg"
    assert flood["Medicine Kit"]["per_family"] == 0.1
    assert "Blanket" not in flood            # retired
    assert "Sleeping Mat" not in flood       # not in this catalog


def test_an_item_waiting_for_review_is_never_suggested(api):
    """F-15: a guest can type in a template item the catalog doesn't have yet
    (here "Clothing"). Until CSWS approves it, no template suggests it."""
    client, _ = api
    db = database.SessionLocal()
    try:
        if not db.get(DisasterType, 1):
            db.add(DisasterType(disaster_type_id=1, type_name="Flood"))
        if not db.query(Item).filter_by(item_name="Rice").first():
            db.add(Item(item_name="Rice", category="Relief", unit_of_measure="kg"))
        clothing = db.query(Item).filter_by(item_name="Clothing").first()
        if clothing is None:
            db.add(Item(item_name="Clothing", category="Other", unit_of_measure="pcs",
                        pending_review=True))
        else:
            clothing.pending_review = True
        db.commit()
    finally:
        db.close()

    templates = {t["name"]: t for t in ok(client.get("/lookups"))["need_templates"]}
    flood = {line["item_name"] for line in templates["Flood"]["items"]}
    assert "Rice" in flood                   # the template itself still works
    assert "Clothing" not in flood           # waiting for review (F-15)
