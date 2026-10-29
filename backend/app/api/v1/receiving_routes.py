from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy.orm import Session

from core.database import get_db
from core.auth import barangay_scope, require_role
from models.physical_donation_model import PhysicalDonation
from models.received_goods_model import ReceivedGoods
from schemas.physical_donation_schema import PhysicalDonationResponse
from models.user_rbac_model import User
from models.inventory_model import Inventory
from schemas.received_goods_schema import ReceivedGoodsCreate, ReceivedGoodsResponse
from core.notifications import notify, notify_many, user_ids_with_role
from services.inventory import add_received_stock
from services.donation_entries import ENTRY_SORTS, build_entries, filter_and_sort, group_by_report
from services.donation_expiry import CLOSED, close_rows, expire_overdue, nice_date


from typing import Optional
from pydantic import ConfigDict
from pydantic import BaseModel, Field
from models.item_model import Item
from datetime import datetime
from core.audit import log_action
from models.guest_donor_model import GuestDonor
from models.report import DisasterReport, DisasterType, Barangay

router = APIRouter(prefix="/donations", tags=["CSWS Receiving"])

# Daniel (Oct 10): tell the donor what happens next, in order.
RECEIVED_BODY = ("CSWS received your donation and is checking it. "
                 "Next, the CMO acknowledges it.")


@router.get("/pending")
def list_pending_donations(
    db: Session = Depends(get_db),
    current_user: User = Depends(require_role("CSWS Main Office", "Administrator")),
):
    expire_overdue(db)
    return db.query(PhysicalDonation).filter(PhysicalDonation.status == "Pending").all()


class InventoryResponse(BaseModel):
    inventory_id: int
    item_id: int
    item_name: str
    unit: Optional[str] = None
    report_id: int
    report_label: Optional[str] = None
    quantity: int
    last_updated: datetime

    model_config = ConfigDict(from_attributes=True)


@router.get("/inventory", response_model=list[InventoryResponse])
def view_inventory(
    report_id: Optional[int] = None,
    db: Session = Depends(get_db),
    current_user: User = Depends(require_role("CSWS Main Office", "Administrator")),
):
    query = db.query(Inventory, Item.item_name, Item.unit_of_measure).join(Item, Inventory.item_id == Item.item_id)
    if report_id is not None:
        query = query.filter(Inventory.report_id == report_id)

    results = query.order_by(Inventory.report_id, Item.item_name).all()
    labels = _report_labels(db, {inv.report_id for inv, _, _ in results})
    return [
        InventoryResponse(
            inventory_id=inv.inventory_id,
            item_id=inv.item_id,
            item_name=item_name,
            unit=unit,
            report_id=inv.report_id,
            report_label=labels.get(inv.report_id),
            quantity=inv.quantity,
            last_updated=inv.last_updated,
        )
        for inv, item_name, unit in results
    ]


def _report_labels(db: Session, report_ids) -> dict:
    if not report_ids:
        return {}
    types = {t.disaster_type_id: t.type_name for t in db.query(DisasterType).all()}
    brgys = {b.barangay_id: b.barangay_name for b in db.query(Barangay).all()}
    return {
        r.report_id: f"#{r.report_id} {r.disaster_label(types)} - {brgys.get(r.barangay_id, 'Barangay')}"
        for r in db.query(DisasterReport).filter(DisasterReport.report_id.in_(report_ids)).all()
    }


# UC-CM1 step 2: identify the donation entry by its QR reference (scanned or
# typed). Alt flow 2a: if the code cannot be read, search manually instead.
@router.get("/by-qr/{qr_reference}")
def find_by_qr(
    qr_reference: str,
    db: Session = Depends(get_db),
    current_user: User = Depends(require_role("CSWS Main Office", "Administrator")),
):
    d = db.query(PhysicalDonation).filter(
        PhysicalDonation.qr_reference == qr_reference.strip().upper()
    ).first()
    if d is None:
        raise HTTPException(status_code=404, detail=f"No donation with reference {qr_reference}")
    item = db.get(Item, d.item_id)
    if d.user_id:
        donor_user = db.get(User, d.user_id)
        donor = f"{donor_user.first_name} {donor_user.last_name}".strip() if donor_user else "Donor"
    else:
        guest = db.get(GuestDonor, d.guest_donor_id) if d.guest_donor_id else None
        donor = f"{guest.full_name} (guest)" if guest else "Guest"
    received = db.query(ReceivedGoods).filter(ReceivedGoods.donation_id == d.donation_id).first()
    return {
        "donation_id": d.donation_id,
        "qr_reference": d.qr_reference,
        "status": d.status,
        "item_id": d.item_id,
        "item_name": item.item_name if item else None,
        "unit": item.unit_of_measure if item else None,
        "quantity": d.quantity,
        "packaging": d.packaging,
        "estimated_value": d.estimated_value,
        "handover_method": d.handover_method,
        "pickup_address": d.pickup_address,
        "donor": donor,
        "report_id": d.report_id,
        "report_label": _report_labels(db, {d.report_id}).get(d.report_id),
        "actual_quantity_received": received.actual_quantity if received else None,
        "created_at": d.created_at,
    }


def _receive_line(db: Session, current_user: User, donation: PhysicalDonation,
                  actual_quantity: int, notes: Optional[str],
                  item_id: Optional[int] = None) -> ReceivedGoods:
    """UC-CM1 steps 3-8 for one item: record the actual quantity accepted
    (alt 4a: may be less than declared), mark it Received and add it to the
    report's inventory. Single receive and entry receive both use this.
    Does not commit."""
    if donation.status in CLOSED:
        # Plain message for the person at the counter: what happened, what to do.
        when = nice_date(donation.closed_at)
        raise HTTPException(
            status_code=400,
            detail=f"This donation was marked {donation.status}{' on ' + when if when else ''}. "
                   f"Tap Reinstate first if the donor is handing it over now.",
        )
    if donation.status != "Pending":
        raise HTTPException(status_code=400, detail=f"Donation is already '{donation.status}', cannot receive again")
    # Per-item fulfillment (Oct 2026): staff can say what the goods really
    # are before they enter the inventory. actual_quantity is then in THAT
    # item's base unit. Only counted toward a need of the same item.
    if item_id is not None and item_id != donation.item_id:
        new_item = db.get(Item, item_id)
        if new_item is None or not new_item.active:
            raise HTTPException(status_code=422, detail="Choose an item from the list.")
        log_action(db, current_user, "RECLASSIFY DONATION", "physical_donations", donation.donation_id,
                   old={"item_id": donation.item_id}, new={"item_id": item_id})
        donation.item_id = item_id
    receipt = ReceivedGoods(
        donation_id=donation.donation_id,
        actual_quantity=actual_quantity,
        received_by_user_id=current_user.user_id,
        notes=notes,
    )
    db.add(receipt)
    donation.status = "Received"
    # Same transaction as the receipt and the status change (5.1.3).
    add_received_stock(db, donation.item_id, donation.report_id, actual_quantity)
    log_action(db, current_user, "RECEIVE DONATION", "physical_donations", donation.donation_id,
               old={"status": "Pending"},
               new={"status": "Received", "declared": donation.quantity,
                    "actual_quantity": actual_quantity})
    return receipt


@router.post("/receive", response_model=ReceivedGoodsResponse)
def receive_donation(
    payload: ReceivedGoodsCreate,
    db: Session = Depends(get_db),
    current_user: User = Depends(require_role("CSWS Main Office", "Administrator")),
):
    donation = db.query(PhysicalDonation).filter(
        PhysicalDonation.donation_id == payload.donation_id
    ).with_for_update().populate_existing().first()     # F-06: a second scan waits, then sees "Received"
    if not donation:
        raise HTTPException(status_code=404, detail="Donation not found")

    receipt = _receive_line(db, current_user, donation, payload.actual_quantity, payload.notes,
                            payload.item_id)
    notify_many(db, user_ids_with_role(db, ["CMO Representative"]),
                "donation_awaiting_confirmation", "Donation awaiting acknowledgement",
                f"Donation #{donation.donation_id} was received by CSWS and needs the CMO's acknowledgement.",
                # problema_napud 4.1: tapping it opens this entry.
                entity_type="donation", entity_id=donation.donation_id)
    if donation.user_id:
        notify(db, donation.user_id, "donation_received",
               title=f"Donation entry {donation.batch_reference or donation.qr_reference} received",
               body=RECEIVED_BODY,
               entity_type="donation", entity_id=donation.donation_id)
    db.commit()
    db.refresh(receipt)
    return receipt


NOT_BROUGHT = "Not brought to CSWS"


class EntryReceiveLine(BaseModel):
    donation_id: int
    actual_quantity: int = Field(gt=0)   # in the item's base unit
    item_id: Optional[int] = None        # what it really is (see _receive_line)


class EntryReceive(BaseModel):
    items: list[EntryReceiveLine] = []
    # Oct 13 concerns: items the donor did not bring. They are closed
    # ("Not brought to CSWS", kept for the record) instead of staying
    # Pending, so the entry reads Received, not Partly Received.
    not_brought: list[int] = []
    notes: Optional[str] = None


# UC-CM1 for a whole entry (one QR = one batch_reference): every listed item
# is received with its actual quantity in one transaction, so either all of
# them reach the inventory or none do. Items left out stay Pending
# (alt 4b: not accepted).
@router.post("/entries/{batch_reference}/receive")
def receive_entry(
    batch_reference: str,
    payload: EntryReceive,
    db: Session = Depends(get_db),
    current_user: User = Depends(require_role("CSWS Main Office", "Administrator")),
):
    ref = batch_reference.strip().upper()
    rows = {
        d.donation_id: d
        for d in db.query(PhysicalDonation).filter(PhysicalDonation.batch_reference == ref)
        .order_by(PhysicalDonation.donation_id)
        .with_for_update().populate_existing().all()     # F-06: one receive of this entry at a time
    }
    if not rows:
        raise HTTPException(status_code=404, detail=f"No donation entry {batch_reference}")
    ids = [line.donation_id for line in payload.items]
    if not ids and not payload.not_brought:
        raise HTTPException(status_code=400, detail="Enter what was received, or mark the items that were not brought.")
    every = ids + list(payload.not_brought)
    if len(set(every)) != len(every):
        raise HTTPException(status_code=400, detail="Each item can be listed only once")
    for donation_id in every:
        if donation_id not in rows:
            raise HTTPException(status_code=400, detail=f"Donation #{donation_id} is not part of entry {ref}")
    for donation_id in payload.not_brought:
        if rows[donation_id].status != "Pending":
            raise HTTPException(status_code=409, detail=f"Donation #{donation_id} is no longer waiting, so it cannot be marked not brought.")

    # F-06: stock rows are locked in item order, like deliveries do.
    for line in sorted(payload.items, key=lambda l: l.item_id or rows[l.donation_id].item_id):
        _receive_line(db, current_user, rows[line.donation_id], line.actual_quantity, payload.notes,
                      line.item_id)
    closed = close_rows([rows[i] for i in payload.not_brought], "Cancelled", NOT_BROUGHT,
                        user_id=current_user.user_id)
    for r in closed:
        log_action(db, current_user, "NOT BROUGHT", "physical_donations", r.donation_id,
                   old={"status": "Pending"}, new={"status": "Cancelled", "reason": NOT_BROUGHT})
    if not ids:
        db.commit()
        return {"batch_reference": ref, "received": [], "not_brought": list(payload.not_brought),
                "pending_items": sum(1 for d in rows.values() if d.status == "Pending")}

    first = next(iter(rows.values()))
    notify_many(db, user_ids_with_role(db, ["CMO Representative"]),
                "donation_awaiting_confirmation", "Donation awaiting acknowledgement",
                f"Donation {ref} ({len(ids)} item(s)) was received by CSWS and needs the CMO's acknowledgement.",
                # problema_napud 4.1: tapping it opens this entry.
                entity_type="donation", entity_id=ids[0])
    if first.user_id:
        notify(db, first.user_id, "donation_received",
               title=f"Donation entry {ref} received",
               body=RECEIVED_BODY,
               entity_type="donation", entity_id=ids[0])
    db.commit()
    still_pending = sum(1 for d in rows.values() if d.status == "Pending")
    return {
        "batch_reference": ref,
        "received": [
            {"donation_id": line.donation_id, "actual_quantity": line.actual_quantity}
            for line in payload.items
        ],
        "not_brought": list(payload.not_brought),
        "pending_items": still_pending,
    }


# NOTE (6.1): the old POST /donations/{donation_id}/confirm route was removed.
# Official recognition ("Confirmed") belongs ONLY to the CMO, via
# POST /cmo/donations/{donation_id}/confirm in cmo_router.py (manuscript Fig. 14).
# CSWS receiving ends at status "Received".


@router.get("/records")
def donation_records(
    status: Optional[str] = None,
    report_id: Optional[int] = None,
    handover_method: Optional[str] = None,
    q: Optional[str] = None,
    sort: str = Query("newest", pattern="^(" + "|".join(ENTRY_SORTS) + ")$"),
    include_closed: bool = False,
    db: Session = Depends(get_db),
    current_user: User = Depends(require_role(
        "Administrator", "CSWS Main Office", "CMO Representative", "barangay_receiving_rep",
    )),
):
    """Appendix H, Module 4.4 / 4.5: View donation records and monitor
    donation status (Administrator, CSWS Main Office, CMO, Barangay
    Receiving Representative).

    A Barangay Receiving Representative only gets the donations for reports
    in its own assigned barangay (UC-B1 alt 3a), without donor names or CMO
    notes: it follows what is coming for its barangay, not who gave it.

    One record per donation entry (one QR / batch_reference) with its items.
    Filters: status (entry status), report_id, handover_method, q (QR
    reference, donor or item). sort: newest, oldest, most_items, fewest_items,
    due_soonest.

    Expired / Cancelled entries are hidden unless status asks for them
    (status=Expired, Cancelled or Closed) or include_closed=true, so the
    everyday list only shows donations that still need work.
    """
    expire_overdue(db)
    own_barangay = barangay_scope(current_user)
    query = db.query(PhysicalDonation)
    if own_barangay is not None:
        query = query.join(
            DisasterReport, DisasterReport.report_id == PhysicalDonation.report_id
        ).filter(DisasterReport.barangay_id == own_barangay)
    if report_id is not None:
        query = query.filter(PhysicalDonation.report_id == report_id)
    staff = own_barangay is None
    entries = build_entries(db, query.all(), include_donor=staff, include_cmo=staff)
    group_by_report(entries)  # numbers each report's entries (Donation 1, 2 ...)
    if not status and not include_closed:
        entries = [e for e in entries if e["status"] not in CLOSED]
    return filter_and_sort(entries, status=status, handover_method=handover_method, search=q, sort=sort)
