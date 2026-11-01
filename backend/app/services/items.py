"""Picking an item for a need or a donation line (shared by reports and
donations).

Either an item from the list (item_id), or "Something else" (other name +
unit): an existing item with that name is reused, otherwise it is added
with category "Other". Its unit becomes its base unit (services/units.py).
Retired items (items.active = false, e.g. the old gallons water) can no
longer be picked for anything new.

F-15: an item typed in on a donation (donor or guest) is added with
pending_review = true. The donation records it, but it is in no dropdown
until CSWS Main Office or the Administrator approves it
(api/v1/item_routes.py). Items the Disaster Unit adds to a report are
staff-created and added at once; if one matches a waiting item, that item
is approved with it.
"""
from fastapi import HTTPException
from sqlalchemy import func
from sqlalchemy.orm import Session

from models.item_model import Item


def _by_name(db: Session, name: str):
    # Exact, case-insensitive match. Not ilike(): a typed "%" or "_" would be
    # a wildcard and match another item, e.g. "Ric_" -> "Rice" (F-15).
    return (db.query(Item).filter(func.lower(Item.item_name) == name.lower())
            .order_by(Item.active.desc()).first())


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
