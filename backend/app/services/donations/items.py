"""Picking an item for a need or a donation line (shared by reports and
donations).

Either an item from the list (item_id), or "Something else" (other name +
unit): an existing item with that name is reused, otherwise it is added
with category "Other". Its unit becomes its base unit (services/donations/units.py).
Retired items (items.active = false, e.g. the old gallons water) can no
longer be picked for anything new.

F-15 / Concerns Nov 4: an item typed in on a donation (donor or guest) is
added with pending_review = true, which now means "typed by a donor": the
donation records it and CSWS sees it when the goods arrive, but it is in no
dropdown. There is no review step (the manuscript has none). Items the
Disaster Unit adds to a report are staff-created and listed at once; if one
matches a donor-typed item, that item is listed with it.
"""
import re

from fastapi import HTTPException
from sqlalchemy import func
from sqlalchemy.orm import Session

from models.donations.item_model import Item


def _by_name(db: Session, name: str):
    # Exact, case-insensitive match. Not ilike(): a typed "%" or "_" would be
    # a wildcard and match another item, e.g. "Ric_" -> "Rice" (F-15).
    return (db.query(Item).filter(func.lower(Item.item_name) == name.lower())
            .order_by(Item.active.desc()).first())


# Item clean-up (migration f3b8d1c5a9e7): names typed for an item that is
# already in the list, and items that were removed. Without this a typed
# "Bigas" would add a second rice, and a typed "MC Water" would come back as
# "MC Water (L)" next to the retired one.
# Diapar: the catalog may spell it "Diaper" or "Diapers"; a new one is
# added as "Diaper".
ITEM_ALIASES = {"bigas": "Rice", "diapar": "Diaper",
                # Nov 22: one kitchen item (migration b4d8f2a6c0e3).
                "kitchen kit": "Kitchen Set", "kitchen kits": "Kitchen Set",
                "kitchen sets": "Kitchen Set",
                # Nov 22: one clothing item (migration c6e0a4b8d2f5).
                "clothing – upper": "Clothing", "clothing - upper": "Clothing",
                "clothing – lower": "Clothing", "clothing - lower": "Clothing",
                "clothes": "Clothing"}
_ALIAS_SPELLINGS = {"diapar": ("Diaper", "Diapers")}


def alias_names(name: str) -> tuple:
    """The listed names an old or misspelled name stands for, best first:
    "Bigas" -> ("Rice",), "diapar" -> ("Diaper", "Diapers"), else ()."""
    key = (name or "").strip().lower()
    if key not in ITEM_ALIASES:
        return ()
    return _ALIAS_SPELLINGS.get(key, (ITEM_ALIASES[key],))
REMOVED_ITEMS = {"mc water"}


def _base_name(item) -> str:
    """ "Bigas (sacks)" -> "bigas" """
    return re.sub(r"\s*\(.*\)$", "", item.item_name or "").strip().lower()


def listed_items(items: list) -> list:
    """The items a dropdown may offer. Removed items (MC Water) and old names
    whose item is listed too (Bigas next to Rice) are left out, so they are
    gone from the app even before the clean-up migration runs."""
    names = {_base_name(i) for i in items}
    return [i for i in items
            if _base_name(i) not in REMOVED_ITEMS
            and not any(a.lower() in names for a in alias_names(_base_name(i)))]


def resolve_item_id(db: Session, item_id, other_name, other_unit, *, review: bool = False) -> int:
    if item_id is not None:
        item = db.get(Item, item_id)
        if item is None:
            raise HTTPException(status_code=404, detail=f"Item {item_id} not found")
        if not item.active:
            raise HTTPException(status_code=422,
                                detail=f"{item.item_name} is no longer offered. Choose another item.")
        return item_id
    name = (other_name or "").strip()
    if not name:
        raise HTTPException(status_code=422, detail="Choose an item, or enter the name of another item")
    if name.lower() in REMOVED_ITEMS:
        raise HTTPException(status_code=422,
                            detail=f"{name} is no longer offered. Choose another item.")
    spellings = alias_names(name)
    for alias in spellings:
        target = _by_name(db, alias)
        if target is not None and target.active:
            return target.item_id
    if spellings:
        name = spellings[0]   # e.g. "Diaper" not in the list yet: added correctly spelled
    unit = (other_unit or "pcs").strip() or "pcs"
    item = _by_name(db, name)
    if item is not None and not item.active:
        # A retired item keeps its name; this one becomes "Name (unit)". Look
        # that up too, so a second donation reuses it instead of failing on
        # the unique name (F-15: it used to be a 500).
        name = f"{name[:150 - len(unit) - 3]} ({unit})"
        item = _by_name(db, name)
    if item is not None:
        if not item.active:
            raise HTTPException(status_code=422,
                                detail=f"{item.item_name} is no longer offered. Choose another item.")
        if not review and item.pending_review:
            item.pending_review = False   # staff typed the same item: approved
        return item.item_id
    item = Item(item_name=name, category="Other", unit_of_measure=unit, pending_review=review)
    db.add(item)
    db.flush()
    return item.item_id
