"""Inventory per (item, report) — manuscript Inventory module, UC-CM1.

Stock rule used everywhere:
    stock(item, report) = sum(received_goods.actual_quantity)
                        - sum(delivery_items.quantity)
Goods enter when CSWS receives them (UC-CM1) and leave when a delivery is
prepared (5.1.4). CMO confirmation (UC-C1) and its revert change the
donation's status only, never the stock.

add_received_stock() is the ONLY place that adds received goods to the
inventory table; every receive path must call it in the same transaction
as the received_goods insert and the status change.
"""
from sqlalchemy import func
from sqlalchemy.orm import Session

from models.delivery import Delivery, DeliveryItem
from models.inventory_model import Inventory
from models.physical_donation_model import PhysicalDonation
from models.received_goods_model import ReceivedGoods


def add_received_stock(db: Session, item_id: int, report_id: int, quantity: int) -> Inventory:
    """Add `quantity` received units of an item to that report's inventory.
    Does not commit: the caller's transaction (get_db) commits or rolls back
    the receipt, the status change and this together."""
    row = (
        db.query(Inventory)
        .filter(Inventory.item_id == item_id, Inventory.report_id == report_id)
        .first()
    )
    if row is None:
        row = Inventory(item_id=item_id, report_id=report_id, quantity=quantity)
        db.add(row)
    else:
        row.quantity += quantity
    db.flush()
    return row


def expected_stock(db: Session) -> dict:
    """{(item_id, report_id): received - delivered}, from the source tables."""
    received = (
        db.query(PhysicalDonation.item_id, PhysicalDonation.report_id,
                 func.sum(ReceivedGoods.actual_quantity))
        .join(ReceivedGoods, ReceivedGoods.donation_id == PhysicalDonation.donation_id)
        .group_by(PhysicalDonation.item_id, PhysicalDonation.report_id)
        .all()
    )
    delivered = (
        db.query(DeliveryItem.item_id, Delivery.report_id, func.sum(DeliveryItem.quantity))
        .join(Delivery, Delivery.delivery_id == DeliveryItem.delivery_id)
        .group_by(DeliveryItem.item_id, Delivery.report_id)
        .all()
    )
    stock: dict = {}
    for item_id, report_id, qty in received:
        stock[(item_id, report_id)] = stock.get((item_id, report_id), 0) + int(qty or 0)
    for item_id, report_id, qty in delivered:
        stock[(item_id, report_id)] = stock.get((item_id, report_id), 0) - int(qty or 0)
    return stock


def stock_differences(db: Session) -> list:
    """Every (item, report) whose inventory row disagrees with expected_stock(),
    including missing rows. Sorted by report, then item."""
    expected = expected_stock(db)
    current = {(r.item_id, r.report_id): r.quantity for r in db.query(Inventory).all()}
    out = []
    for key in sorted(set(expected) | set(current), key=lambda k: (k[1], k[0])):
        want = expected.get(key, 0)
        have = current.get(key)
        if have != want and not (have is None and want == 0):
            out.append({
                "item_id": key[0],
                "report_id": key[1],
                "inventory": have,          # None = no row at all
                "expected": want,
                "difference": want - (have or 0),
            })
    return out
