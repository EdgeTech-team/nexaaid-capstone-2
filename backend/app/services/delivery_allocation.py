"""Whose goods go on a delivery (Oct 13 concerns, delivery preparation).

Received goods are pooled per report and item (Inventory), so a delivery of
65 kg of rice does not say which donors' rice it was. This service decides
it, the same way every time:

    first received, first sent; donations the CMO already acknowledged
    go before those still waiting for the CMO.

Example: Liza gave 50 kg, then Ana gave 30 kg, both acknowledged. CSWS
sends 65 kg -> all 50 of Liza's and 15 of Ana's. preview() shows that while
the delivery is being prepared and offers "Send 80 to finish Ana's
donation", so most deliveries take whole donations.

A donor's donation then moves to In transit / Delivered / Barangay
confirmed only when ALL its goods reached that step (the least advanced
part decides); until then it stays at the step before, with a note such as
"Rice: 15 of 30 kg sent". There is no "partly delivered" status.

Cancelled deliveries are ignored everywhere, so their goods count as not
sent again. A trip that is undone deletes its deliveries, and with them
their allocations.
"""
from collections import defaultdict
from typing import Iterable

from sqlalchemy import func
from sqlalchemy.orm import Session

from models.delivery import Delivery, DeliveryAllocation, DeliveryItem
from models.physical_donation_model import PhysicalDonation
from models.received_goods_model import ReceivedGoods

# Delivery status -> how far the goods got. Preparing has not left yet.
RANK = {"In Transit": 1, "Delivered": 2, "Confirmed": 3}
# ... and the matching step of the donor's timeline (design/status.dart).
STEP = {1: "In Transit", 2: "Delivered", 3: "Acknowledged"}


def _allocated(db: Session, donation_ids: Iterable[int]) -> dict:
    """donation_id -> quantity already on deliveries that are not cancelled."""
    ids = list(donation_ids)
    if not ids:
        return {}
    rows = (
        db.query(DeliveryAllocation.donation_id, func.sum(DeliveryAllocation.quantity))
        .join(DeliveryItem, DeliveryItem.delivery_item_id == DeliveryAllocation.delivery_item_id)
        .join(Delivery, Delivery.delivery_id == DeliveryItem.delivery_id)
        .filter(DeliveryAllocation.donation_id.in_(ids), Delivery.status != "Cancelled")
        .group_by(DeliveryAllocation.donation_id)
        .all()
    )
    return {d: int(q or 0) for d, q in rows}


def pool(db: Session, report_id: int, item_id: int) -> list:
    """[(donation, received_at, quantity not sent yet)] in the order goods
    are taken: acknowledged first, then oldest received first."""
    rows = (
        db.query(PhysicalDonation, ReceivedGoods)
        .join(ReceivedGoods, ReceivedGoods.donation_id == PhysicalDonation.donation_id)
        .filter(
            PhysicalDonation.report_id == report_id,
            PhysicalDonation.item_id == item_id,
            PhysicalDonation.status.in_(("Received", "Confirmed")),
        )
        .all()
    )
    sent = _allocated(db, [d.donation_id for d, _ in rows])
    out = []
    for d, g in rows:
        left = (g.actual_quantity or 0) - sent.get(d.donation_id, 0)
        if left > 0:
            out.append((d, g.received_at, left))
    out.sort(key=lambda x: (x[0].status != "Confirmed", x[1] is None, x[1], x[0].donation_id))
    return out


def plan(db: Session, report_id: int, item_id: int, quantity: int) -> list:
    """[(donation, take, left before)] for `quantity` of one item."""
    out = []
    need = quantity
    for d, _, left in pool(db, report_id, item_id):
        if need <= 0:
            break
        take = min(left, need)
        out.append((d, take, left))
        need -= take
    return out


def allocate_delivery(db: Session, delivery: Delivery) -> None:
    """Record whose goods each line of a new delivery takes. Call once its
    items are flushed. Lines for the same item are planned one after the
    other, so they never take the same goods twice. If the pool has less
    than the line (stock edited by hand), the rest stays unassigned."""
    lines = (db.query(DeliveryItem).filter(DeliveryItem.delivery_id == delivery.delivery_id)
             .order_by(DeliveryItem.delivery_item_id).all())
    for line in lines:
        for d, take, _ in plan(db, delivery.report_id, line.item_id, line.quantity):
            db.add(DeliveryAllocation(
                delivery_item_id=line.delivery_item_id, donation_id=d.donation_id, quantity=take,
            ))
        db.flush()


def preview(db: Session, report_id: int, lines: Iterable) -> list:
    """For the "Prepare delivery" screen: per item, whose donations the
    entered quantity takes, and the quantity that would finish a donation
    that is only partly taken."""
    from services.donation_entries import _donor_names  # avoid an import cycle

    wanted: dict = defaultdict(int)
    for line in lines:
        wanted[line.item_id] += line.quantity
    out = []
    for item_id, qty in wanted.items():
        steps = plan(db, report_id, item_id, qty)
        users, guests = _donor_names(db, [d for d, _, _ in steps])
        donations = []
        for d, take, left in steps:
            name = (users.get(d.user_id, "Donor") if d.user_id
                    else f"{guests.get(d.guest_donor_id, 'Guest')} (guest)")
            donations.append({
                "donation_id": d.donation_id,
                "batch_reference": d.batch_reference,
                "donor": name,
                "acknowledged": d.status == "Confirmed",
                "take": take,
                "available": left,
                "whole": take == left,
            })
        last = donations[-1] if donations else None
        out.append({
            "item_id": item_id,
            "quantity": qty,
            "assigned": sum(x["take"] for x in donations),
            "donations": donations,
            # e.g. 65 splits Ana's 30 -> 80 finishes it.
            "finish_quantity": (qty + last["available"] - last["take"])
            if last and not last["whole"] else None,
            "finish_donor": last["donor"] if last and not last["whole"] else None,
        })
    return out


def add_delivery_progress(db: Session, entries: list) -> None:
    """Donor screens: how far each entry's goods got.

    Adds lifecycle_status (the timeline step: the entry status, or
    In Transit / Delivered / Acknowledged once ALL its received goods got
    there) and delivery_note ("Rice: 15 of 30 kg sent") while only part of
    them has left."""
    ids = [i["donation_id"] for e in entries for i in e["items"]
           if i["status"] in ("Received", "Confirmed") and i.get("actual_quantity_received")]
    reached: dict = defaultdict(lambda: defaultdict(int))   # donation -> rank -> qty
    if ids:
        rows = (
            db.query(DeliveryAllocation.donation_id, Delivery.status, func.sum(DeliveryAllocation.quantity))
            .join(DeliveryItem, DeliveryItem.delivery_item_id == DeliveryAllocation.delivery_item_id)
            .join(Delivery, Delivery.delivery_id == DeliveryItem.delivery_id)
            .filter(DeliveryAllocation.donation_id.in_(ids), Delivery.status != "Cancelled")
            .group_by(DeliveryAllocation.donation_id, Delivery.status)
            .all()
        )
        for donation_id, status, qty in rows:
            reached[donation_id][RANK.get(status, 0)] += int(qty or 0)

    for e in entries:
        e["lifecycle_status"] = e["status"]
        e["delivery_note"] = None
        if e.get("pending_items"):
            continue   # still waiting for drop-off or pickup
        moved = [i for i in e["items"] if i["donation_id"] in ids]
        if not moved:
            continue
        ranks, notes = [], []
        for i in moved:
            got = reached.get(i["donation_id"], {})
            total = i["actual_quantity_received"]
            rank = 0
            for r in (3, 2, 1):
                if sum(q for k, q in got.items() if k >= r) >= total:
                    rank = r
                    break
            ranks.append(rank)
            sent = sum(q for k, q in got.items() if k >= 1)
            if 0 < sent < total:
                notes.append(f"{i['item_name']}: {sent} of {total} {i['unit']} sent".replace("  ", " ").strip())
        if min(ranks):
            e["lifecycle_status"] = STEP[min(ranks)]
        if notes:
            e["delivery_note"] = "; ".join(notes) + ". The rest goes on a later delivery."
