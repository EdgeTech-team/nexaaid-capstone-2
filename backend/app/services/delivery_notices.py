"""Who hears about a delivery (Oct 17 run-through of Appendix H).

Deliveries record whose donations they carry (delivery_allocations), so
the donors of those donations can follow them, not only the staff:

  * donors: when their donation is on the way, delivered, confirmed by the
    barangay, rescheduled, sent back to the office, or its delivery is
    cancelled (one notice per donation entry, guests have no account);
  * the barangay's representative: when aid for the barangay is prepared,
    so they can get ready to receive it.
"""
from collections import defaultdict
from typing import Iterable

from sqlalchemy.orm import Session

from core.notifications import notify_event, notify_event_many, user_ids_with_role
from models.delivery import Delivery, DeliveryAllocation, DeliveryItem
from models.physical_donation_model import PhysicalDonation
from models.report import Barangay

# Delivery status -> the donor's event.
STATUS_EVENTS = {"In Transit": "donation_in_transit", "Delivered": "donation_delivered"}


def _barangay(db: Session, delivery: Delivery) -> str:
    b = db.get(Barangay, delivery.destination_barangay_id)
    return b.barangay_name if b else "the barangay"


def donor_entries(db: Session, delivery_id: int) -> dict:
    """{donor user_id: {batch_reference: first donation_id}} on this delivery."""
    rows = (
        db.query(PhysicalDonation.user_id, PhysicalDonation.batch_reference, PhysicalDonation.donation_id)
        .join(DeliveryAllocation, DeliveryAllocation.donation_id == PhysicalDonation.donation_id)
        .join(DeliveryItem, DeliveryItem.delivery_item_id == DeliveryAllocation.delivery_item_id)
        .filter(DeliveryItem.delivery_id == delivery_id, PhysicalDonation.user_id.isnot(None))
        .order_by(PhysicalDonation.donation_id)
        .all()
    )
    out: dict = defaultdict(dict)
    for user_id, ref, donation_id in rows:
        out[user_id].setdefault(ref, donation_id)
    return out


def tell_donors(db: Session, delivery: Delivery, event: str, **ctx) -> int:
    """One notice per donor's entry on this delivery. Returns how many."""
    sent = 0
    where = _barangay(db, delivery)
    for user_id, entries in donor_entries(db, delivery.delivery_id).items():
        for ref, donation_id in entries.items():
            notify_event(db, user_id, event, "donation", donation_id, batch_no=ref,
                         barangay=where, delivery_id=delivery.delivery_id, **ctx)
            sent += 1
    return sent


def tell_status(db: Session, delivery: Delivery) -> None:
    event = STATUS_EVENTS.get(delivery.status)
    if event:
        tell_donors(db, delivery, event)


def tell_barangay_prepared(db: Session, deliveries: Iterable[Delivery]) -> None:
    """The receiving barangay's representative hears that aid is coming."""
    for d in deliveries:
        reps = user_ids_with_role(db, ["Barangay Receiving Representative"],
                                  barangay_id=d.destination_barangay_id)
        when = d.delivery_date.strftime("%b %d, %Y %I:%M %p") if d.delivery_date else "to be set"
        notify_event_many(db, reps, "delivery_prepared", "delivery", d.delivery_id,
                          title=f"Delivery #{d.delivery_id}", barangay=_barangay(db, d), date=when)
