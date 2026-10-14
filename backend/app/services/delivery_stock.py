"""Releasing goods from a report's inventory into a delivery (5.1.4).

Inventory is per (item, report) (Table 34: "Inventory is linked to specific
report records"), so every delivery line takes stock from ONE report. Used
by POST /deliveries/ and by trips (several reports on one truck).

The messages are written for the person preparing the delivery, not for a
developer: they name the item and say how much is left.
"""
from fastapi import HTTPException
from sqlalchemy.orm import Session

from models.inventory_model import Inventory
from models.item_model import Item


def _item_label(db: Session, item_id: int) -> tuple:
    item = db.get(Item, item_id)
    if item is None:
        return f"item #{item_id}", ""
    return item.item_name, item.unit_of_measure or ""


def report_stock(db: Session, report_id: int) -> dict:
    """{item_id: quantity left} for one report, only items with stock."""
    return {
        inv.item_id: inv.quantity
        for inv in db.query(Inventory).filter(Inventory.report_id == report_id).all()
        if inv.quantity > 0
    }


def check_stock(db: Session, report_id: int, lines, report_name: str = "this report") -> dict:
    """Raise 409 with a plain message if the lines ask for more than the
    report has. lines: objects with item_id and quantity; the same item may
    appear twice (the quantities add up). Returns {item_id: (row, wanted)}.
    Takes nothing yet: call take_stock() once every report has passed."""
    wanted: dict = {}
    for line in lines:
        wanted[line.item_id] = wanted.get(line.item_id, 0) + line.quantity

    rows = {
        inv.item_id: inv
        for inv in db.query(Inventory).filter(
            Inventory.report_id == report_id, Inventory.item_id.in_(list(wanted))
        ).all()
    }
    for item_id, qty in wanted.items():
        available = rows[item_id].quantity if item_id in rows else 0
        if qty > available:
            name, unit = _item_label(db, item_id)
            if available <= 0:
                detail = f"No more stock of {name} for {report_name}."
            else:
                # Starts with "Not enough stock" like the original message.
                detail = (f"Not enough stock: only {available} {unit} of {name} left "
                          f"for {report_name}, but {qty} was entered.").replace("  ", " ")
            raise HTTPException(status_code=409, detail=detail)
    return {item_id: (rows[item_id], qty) for item_id, qty in wanted.items()}


def take_stock(checked: dict) -> None:
    """Deduct what check_stock() approved."""
    for row, qty in checked.values():
        row.quantity -= qty
