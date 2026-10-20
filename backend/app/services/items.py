"""Picking an item for a need or a donation line (shared by reports and
donations).

Either an item from the list (item_id), or "Something else" (other name +
unit): an existing item with that name is reused, otherwise it is added
with category "Other". Its unit becomes its base unit (services/units.py).
Retired items (items.active = false, e.g. the old gallons water) can no
longer be picked for anything new.
"""
from fastapi import HTTPException
from sqlalchemy.orm import Session

from models.item_model import Item


def resolve_item_id(db: Session, item_id, other_name, other_unit) -> int:
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
    item = (db.query(Item).filter(Item.item_name.ilike(name))
            .order_by(Item.active.desc()).first())
    if item is None or not item.active:
        item = Item(
            item_name=name if item is None else f"{name} ({(other_unit or 'pcs').strip()})",
            category="Other",
            unit_of_measure=(other_unit or "pcs").strip() or "pcs",
        )
        db.add(item)
        db.flush()
    return item.item_id
