"""Suggested needs per disaster type (Module 3, Oct 2026).

When a report's disaster type is picked, the app fills the needs list with
these basic items, each multiplied by the affected families and rounded up.
The reporter can still change, remove or add any line before submitting.

Amounts are per family for the first few days of relief. They are the
team's working assumptions (rice follows the 6 kg of a DSWD family food
pack); adjust them here. Fractions are for items given per group of
families, e.g. 0.1 Medicine Kit = one box per 10 families.

Items are matched by name to the active, reviewed catalog (database/seeds);
a name that is missing, retired or still waiting for review (F-15) is skipped.

"""
from sqlalchemy.orm import Session

from models.item_model import Item
from models.report import DisasterType

_FOOD = {"Rice": 6, "Canned Goods": 8, "Noodles": 4, "Drinking Water": 20}
_SHELTER = {"Hygiene Kit": 1, "Blanket": 2, "Sleeping Mat": 1}

NEED_TEMPLATES = {
    "Flood": {**_FOOD, **_SHELTER, "Clothing": 1, "Medicine Kit": 0.1},
    "Flash Flood": {**_FOOD, **_SHELTER, "Clothing": 1, "Medicine Kit": 0.1},
    "Typhoon": {**_FOOD, **_SHELTER, "Clothing": 1, "Medicine Kit": 0.1},
    "Storm Surge": {**_FOOD, **_SHELTER, "Clothing": 1, "Medicine Kit": 0.1},
    "Tsunami": {**_FOOD, **_SHELTER, "Clothing": 2, "Medicine Kit": 0.2},
    # Families lose the house and everything in it.
    "Fire": {**_FOOD, **_SHELTER, "Clothing": 2},
    "Earthquake": {**_FOOD, **_SHELTER, "Medicine Kit": 0.2},
    "Landslide": {**_FOOD, **_SHELTER, "Medicine Kit": 0.2},
    "Drought": {**_FOOD, "Drinking Water": 40},
    "Disease Outbreak": {**_FOOD, "Hygiene Kit": 1, "Medicine Kit": 0.5},
}



def need_templates(db: Session) -> list:
    """[{id: disaster_type_id, name, items: [{item_id, item_name, unit, per_family}]}]
    for the disaster types that have a template, as /lookups sends it."""
    items = {
        i.item_name.lower(): i
        for i in db.query(Item).filter(Item.active.is_(True), Item.pending_review.is_(False)).all()
    }
    out = []
    for t in db.query(DisasterType).order_by(DisasterType.disaster_type_id).all():
        template = NEED_TEMPLATES.get(t.type_name)
        if not template:
            continue
        lines = [
            {"item_id": items[name.lower()].item_id, "item_name": items[name.lower()].item_name,
             "unit": items[name.lower()].unit_of_measure, "per_family": per_family}
            for name, per_family in template.items()
            if name.lower() in items
        ]
        if lines:
            out.append({"id": t.disaster_type_id, "name": t.type_name, "items": lines})
    return out
