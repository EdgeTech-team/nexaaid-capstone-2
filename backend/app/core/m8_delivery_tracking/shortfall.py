"""J5 / NF-010 (team agreement Nov 18, 2026, A3): CSWS shortfall review.

A short delivery is a Confirmed delivery where the Barangay Receiving
Representative counted less than CSWS sent on at least one line
(receipt_items.received_quantity < expected_quantity, J1 / NF-009). CSWS
Main Office records why: Damaged, Lost in transit, Miscount at office or
Miscount at barangay, with an optional note.

A review only records the cause. It never restores stock (office miscounts
are fixed with the existing inventory adjustment) and never changes
fulfillment or priority, which already use what the barangay counted. A
new review replaces the cause on the delivery; the audit log keeps every
review (REVIEW DELIVERY SHORTFALL, with the old and new values).
"""
from collections import defaultdict
from typing import List, Optional

from fastapi import HTTPException
from sqlalchemy import select
from sqlalchemy.orm import Session

from core.shared.audit import log_action
from core.m8_delivery_tracking.delivery_model import Delivery, DeliveryItem, ReceiptItem
from core.reference_data.item_model import Item
from core.m1_user_management.user_rbac_model import User
from core.m8_delivery_tracking.delivery_schema import ShortDelivery, ShortLine
from core.m8_delivery_tracking.delivery_views import report_labels
from core.m4_donation_management.donation_expiry import now_utc

REVIEW_ACTION = "REVIEW DELIVERY SHORTFALL"


def short_delivery_ids():
    """SQL: ids of deliveries with at least one line counted short."""
    return (select(DeliveryItem.delivery_id)
            .join(ReceiptItem, ReceiptItem.delivery_item_id == DeliveryItem.delivery_item_id)
            .where(ReceiptItem.received_quantity < ReceiptItem.expected_quantity))


def short_deliveries_query(db: Session, reviewed: Optional[bool] = None):
    """Confirmed, not deleted, short deliveries; newest first.
    reviewed=True: only reviewed ones; False: only those still to review."""
    q = db.query(Delivery).filter(Delivery.status == "Confirmed",
                                  Delivery.deleted_at.is_(None),
                                  Delivery.delivery_id.in_(short_delivery_ids()))
    if reviewed is True:
        q = q.filter(Delivery.discrepancy_reviewed_at.isnot(None))
    elif reviewed is False:
        q = q.filter(Delivery.discrepancy_reviewed_at.is_(None))
    return q.order_by(Delivery.delivery_id.desc())


def _short_lines(db: Session, deliveries: List[Delivery]) -> dict:
    """{delivery_id: [ShortLine]} for these deliveries, in two queries."""
    ids = [d.delivery_id for d in deliveries]
    rows = (db.query(DeliveryItem, ReceiptItem)
            .join(ReceiptItem, ReceiptItem.delivery_item_id == DeliveryItem.delivery_item_id)
            .filter(DeliveryItem.delivery_id.in_(ids or [-1]),
                    ReceiptItem.received_quantity < ReceiptItem.expected_quantity)
            .order_by(DeliveryItem.delivery_item_id).all())
    items = {i.item_id: i for i in db.query(Item).filter(
        Item.item_id.in_({line.item_id for line, _ in rows} or {-1})).all()}
    out = defaultdict(list)
    for line, counted in rows:
        item = items.get(line.item_id)
        out[line.delivery_id].append(ShortLine(
            delivery_item_id=line.delivery_item_id,
            item_id=line.item_id,
            item_name=item.item_name if item else f"Item #{line.item_id}",
            unit=item.unit_of_measure if item else None,
            expected_quantity=counted.expected_quantity,
            received_quantity=counted.received_quantity,
            discrepancy_reason=counted.discrepancy_reason,
            discrepancy_note=counted.discrepancy_note,
        ))
    return out


def _name(user: Optional[User]) -> Optional[str]:
    if user is None:
        return None
    return f"{user.first_name or ''} {user.last_name or ''}".strip() or None


def views(db: Session, deliveries: List[Delivery]) -> List[ShortDelivery]:
    """The short deliveries as the list shows them."""
    if not deliveries:
        return []
    lines = _short_lines(db, deliveries)
    labels = report_labels(db, {d.report_id for d in deliveries})
    reviewers = {u.user_id: u for u in db.query(User).filter(User.user_id.in_(
        {d.discrepancy_reviewed_by_user_id for d in deliveries} - {None} or {-1})).all()}
    return [
        ShortDelivery(
            delivery_id=d.delivery_id,
            report_id=d.report_id,
            report_label=labels.get(d.report_id),
            barangay_name=(d.destination_barangay.barangay_name
                           if d.destination_barangay else "Barangay"),
            trip_id=d.trip_id,
            received_at=d.receipt.received_at,
            short_lines=lines.get(d.delivery_id, []),
            cause=d.discrepancy_cause,
            note=d.discrepancy_note,
            reviewed_at=d.discrepancy_reviewed_at,
            reviewed_by=_name(reviewers.get(d.discrepancy_reviewed_by_user_id)),
        )
        for d in deliveries
    ]


def review(db: Session, delivery: Delivery, cause: str, note: Optional[str], user) -> ShortDelivery:
    """Record CSWS Main Office's cause for a short delivery. 409 when the
    delivery is not Confirmed or no line was counted short. Changes no
    stock, fulfillment or priority. Does not commit."""
    if delivery.status != "Confirmed":
        raise HTTPException(
            status_code=409,
            detail=(f"Delivery #{delivery.delivery_id} is {delivery.status}. Only a delivery the "
                    "barangay confirmed can have a shortfall to review."),
        )
    lines = _short_lines(db, [delivery]).get(delivery.delivery_id, [])
    if not lines:
        raise HTTPException(
            status_code=409,
            detail=(f"Delivery #{delivery.delivery_id} has no short line: the barangay counted "
                    "at least what CSWS sent."),
        )
    note = (note or "").strip() or None
    old = {
        "cause": delivery.discrepancy_cause,
        "note": delivery.discrepancy_note,
        "reviewed_at": (delivery.discrepancy_reviewed_at.isoformat()
                        if delivery.discrepancy_reviewed_at else None),
        "reviewed_by_user_id": delivery.discrepancy_reviewed_by_user_id,
    }
    delivery.discrepancy_cause = cause
    delivery.discrepancy_note = note
    delivery.discrepancy_reviewed_at = now_utc()
    delivery.discrepancy_reviewed_by_user_id = user.user_id
    log_action(db, user, REVIEW_ACTION, "deliveries", delivery.delivery_id,
               old=old,
               new={"cause": cause, "note": note,
                    "reviewed_by": _name(user),
                    "short_lines": [{"item_id": line.item_id,
                                     "expected": line.expected_quantity,
                                     "received": line.received_quantity}
                                    for line in lines]})
    db.flush()
    return views(db, [delivery])[0]
