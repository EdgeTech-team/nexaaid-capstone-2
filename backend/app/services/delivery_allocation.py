"""Whose goods go on a delivery (Oct 13 concerns, delivery preparation).

Received goods are pooled per report and item (Inventory), so a delivery of
65 kg of rice does not say which donors' rice it was. This service decides
it, the same way every time:

    first received, first sent; donations the CMO already acknowledged
    go before those still waiting for the CMO.

Oct 13 (team): a delivery prepared in the app takes EVERY acknowledged
donation of its report that has not gone out yet (ready_lines /
ready_donations). Donations are for that report, so they all go; a full
truck is handled with a DRRMO logistics request, not by sending less.
Donations still waiting for the CMO stay for the next delivery.

A donor's donation then moves to In transit / Delivered / Barangay
confirmed with its delivery. Only deliveries made the old way (typed
quantities, through the API or before this change) can take part of a
donation; then the least advanced part decides and a note says
"Rice: 15 of 30 kg sent".

Cancelled deliveries are ignored everywhere, so their goods count as not
sent again. A trip that is undone deletes its deliveries, and with them
their allocations.
"""
from collections import defaultdict
from typing import Iterable, Optional

from fastapi import HTTPException

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


def pool(db: Session, report_id: int, item_id: int, refs: Optional[set] = None) -> list:
    """[(donation, received_at, quantity not sent yet)] in the order goods
    are taken: acknowledged first, then oldest received first. refs: only
    these donation entries (batch references), when Main Office chose them."""
    q = (
        db.query(PhysicalDonation, ReceivedGoods)
        .join(ReceivedGoods, ReceivedGoods.donation_id == PhysicalDonation.donation_id)
        .filter(
            PhysicalDonation.report_id == report_id,
            PhysicalDonation.item_id == item_id,
            PhysicalDonation.status.in_(("Received", "Confirmed")),
        )
    )
    if refs is not None:
        q = q.filter(PhysicalDonation.batch_reference.in_(list(refs)))
    rows = q.all()
    sent = _allocated(db, [d.donation_id for d, _ in rows])
    out = []
    for d, g in rows:
        left = (g.actual_quantity or 0) - sent.get(d.donation_id, 0)
        if left > 0:
            out.append((d, g.received_at, left))
    out.sort(key=lambda x: (x[0].status != "Confirmed", x[1] is None, x[1], x[0].donation_id))
    return out


def plan(db: Session, report_id: int, item_id: int, quantity: int, refs: Optional[set] = None) -> list:
    """[(donation, take, left before)] for `quantity` of one item."""
    out = []
    need = quantity
    for d, _, left in pool(db, report_id, item_id, refs):
        if need <= 0:
            break
        take = min(left, need)
        out.append((d, take, left))
        need -= take
    return out


def ready_refs(db: Session, report_id: int) -> set:
    """Batch references of the acknowledged entries not sent yet."""
    return {e["batch_reference"] for e in ready_donations(db, report_id)["entries"]}


def chosen_refs(db: Session, report_id: int, refs: Optional[Iterable[str]]) -> set:
    """Oct 15 (team): the donation entries this delivery takes, always WHOLE.
    None = every acknowledged entry of the report. Otherwise the ones Main
    Office kept ticked; the others wait for the next delivery. Refuses an
    entry that is not acknowledged, not this report's, or already sent."""
    ready = ready_refs(db, report_id)
    if refs is None:
        return ready
    want = {(r or "").strip().upper() for r in refs if (r or "").strip()}
    wrong = sorted(want - ready)
    if wrong:
        raise HTTPException(
            status_code=409,
            detail="These donations cannot go on this delivery (not acknowledged by the CMO, "
                   f"already sent, or for another report): {', '.join(wrong)}",
        )
    return want


def ready_lines(db: Session, report_id: int, refs: Optional[set] = None) -> list:
    """The lines [{item_id, quantity}] that carry the chosen entries whole
    (all acknowledged entries when refs is None)."""
    refs = ready_refs(db, report_id) if refs is None else refs
    if not refs:
        return []
    item_ids = {i for (i,) in db.query(PhysicalDonation.item_id).filter(
        PhysicalDonation.report_id == report_id,
        PhysicalDonation.batch_reference.in_(list(refs))).distinct()}
    out = []
    for item_id in sorted(item_ids):
        qty = sum(left for d, _, left in pool(db, report_id, item_id, refs) if d.status == "Confirmed")
        if qty > 0:
            out.append(_Line(item_id, qty))
    return out


class _Line:
    """Same shape as a DeliveryItemCreate (item_id, quantity)."""
    def __init__(self, item_id: int, quantity: int):
        self.item_id, self.quantity = item_id, quantity

    def model_dump(self) -> dict:
        return {"item_id": self.item_id, "quantity": self.quantity}


def ready_donations(db: Session, report_id: int) -> dict:
    """For the Prepare delivery screen: every donation entry that goes on
    the next delivery of this report (acknowledged, not sent yet), with its
    items, and how many entries still wait for the CMO."""
    from models.item_model import Item
    from services.donation_entries import _donor_names  # avoid an import cycle

    rows = (
        db.query(PhysicalDonation)
        .filter(PhysicalDonation.report_id == report_id,
                PhysicalDonation.status.in_(("Received", "Confirmed")))
        .order_by(PhysicalDonation.donation_id).all()
    )
    received = {g.donation_id: g.actual_quantity for g in db.query(ReceivedGoods)
                .filter(ReceivedGoods.donation_id.in_([d.donation_id for d in rows]))}
    sent = _allocated(db, [d.donation_id for d in rows])
    items = {i.item_id: i for i in db.query(Item).all()}
    users, guests = _donor_names(db, rows)
    entries: dict = {}
    waiting: set = set()
    for d in rows:
        left = (received.get(d.donation_id) or 0) - sent.get(d.donation_id, 0)
        if left <= 0:
            continue
        if d.status != "Confirmed":
            waiting.add(d.batch_reference)
            continue
        e = entries.setdefault(d.batch_reference, {
            "batch_reference": d.batch_reference,
            "donor": (users.get(d.user_id, "Donor") if d.user_id
                      else f"{guests.get(d.guest_donor_id, 'Guest')} (guest)"),
            "items": [],
        })
        it = items.get(d.item_id)
        e["items"].append({"item_id": d.item_id, "item_name": it.item_name if it else "Item",
                           "unit": it.unit_of_measure if it else "", "quantity": left})
    totals: dict = {}
    for e in entries.values():
        for i in e["items"]:
            t = totals.setdefault(i["item_id"], {**i, "quantity": 0})
            t["quantity"] += i["quantity"]
    return {
        "report_id": report_id,
        "entries": list(entries.values()),
        "totals": list(totals.values()),
        "waiting_for_cmo": len(waiting - set(entries)),
    }


def allocate_delivery(db: Session, delivery: Delivery, refs: Optional[set] = None) -> None:
    """Record whose goods each line of a new delivery takes. Call once its
    items are flushed. Lines for the same item are planned one after the
    other, so they never take the same goods twice. If the pool has less
    than the line (stock edited by hand), the rest stays unassigned."""
    lines = (db.query(DeliveryItem).filter(DeliveryItem.delivery_id == delivery.delivery_id)
             .order_by(DeliveryItem.delivery_item_id).all())
    for line in lines:
        for d, take, _ in plan(db, delivery.report_id, line.item_id, line.quantity, refs):
            db.add(DeliveryAllocation(
                delivery_item_id=line.delivery_item_id, donation_id=d.donation_id, quantity=take,
            ))
        db.flush()


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
