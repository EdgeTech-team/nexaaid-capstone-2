from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session

from core.database import get_db
from core.auth import require_role
from models.physical_donation_model import PhysicalDonation
from models.received_goods_model import ReceivedGoods
from schemas.physical_donation_schema import PhysicalDonationResponse
from models.user_rbac_model import User
from models.inventory_model import Inventory
from schemas.received_goods_schema import ReceivedGoodsCreate, ReceivedGoodsResponse
from core.notifications import notify

from typing import Optional
from pydantic import BaseModel
from models.item_model import Item
from datetime import datetime
from core.audit import log_action
from models.guest_donor_model import GuestDonor
from models.report import DisasterReport, DisasterType, Barangay

router = APIRouter(prefix="/donations", tags=["CSWS Receiving"])


@router.get("/pending")
def list_pending_donations(
    db: Session = Depends(get_db),
    current_user: User = Depends(require_role("CSWS Main Office", "Administrator")),
):
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

    class Config:
        from_attributes = True


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
        r.report_id: f"#{r.report_id} {types.get(r.disaster_type_id, 'Disaster')} - {brgys.get(r.barangay_id, 'Barangay')}"
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


@router.post("/receive", response_model=ReceivedGoodsResponse)
def receive_donation(
    payload: ReceivedGoodsCreate,
    db: Session = Depends(get_db),
    current_user: User = Depends(require_role("CSWS Main Office", "Administrator")),
):
    donation = db.query(PhysicalDonation).filter(
        PhysicalDonation.donation_id == payload.donation_id
    ).first()
    if not donation:
        raise HTTPException(status_code=404, detail="Donation not found")
    if donation.status != "Pending":
        raise HTTPException(status_code=400, detail=f"Donation is already '{donation.status}', cannot receive again")

    receipt = ReceivedGoods(
        donation_id=payload.donation_id,
        actual_quantity=payload.actual_quantity,
        received_by_user_id=current_user.user_id,
        notes=payload.notes,
    )
    db.add(receipt)

    donation.status = "Received"

    inventory_item = db.query(Inventory).filter(
        Inventory.item_id == donation.item_id,
        Inventory.report_id == donation.report_id,
    ).first()

    if inventory_item:
        inventory_item.quantity += payload.actual_quantity
    else:
        inventory_item = Inventory(
            item_id=donation.item_id,
            report_id=donation.report_id,
            quantity=payload.actual_quantity,
        )
        db.add(inventory_item)

    db.flush()
    log_action(db, current_user, "RECEIVE DONATION", "physical_donations", donation.donation_id,
               old={"status": "Pending"},
               new={"status": "Received", "declared": donation.quantity,
                    "actual_quantity": payload.actual_quantity})
    if donation.user_id:
        notify(db, donation.user_id, "donation_received",
               title=f"Donation #{donation.donation_id} received",
               body="Your donation arrived and is being checked.",
               entity_type="donation", entity_id=donation.donation_id)
    db.commit()
    db.refresh(receipt)
    return receipt

@router.post("/{donation_id}/confirm", response_model=PhysicalDonationResponse)
def confirm_donation(
    donation_id: int,
    db: Session = Depends(get_db),
    current_user: User = Depends(require_role("CSWS Main Office", "Administrator")),
):
    donation = db.query(PhysicalDonation).filter(
        PhysicalDonation.donation_id == donation_id
    ).first()
    if not donation:
        raise HTTPException(status_code=404, detail="Donation not found")
    if donation.status != "Received":
        raise HTTPException(
            status_code=400,
            detail=f"Donation must be 'Received' before it can be confirmed (currently '{donation.status}')",
        )

    donation.status = "Confirmed"
    if donation.user_id:  # guest donors have no account
        notify(db, donation.user_id, "donation_confirmed",
               title=f"Donation #{donation.donation_id} confirmed",
               body="Your donation was received and confirmed. Thank you!",
               entity_type="donation", entity_id=donation.donation_id)
    db.commit()
    db.refresh(donation)
    return donation

@router.get("/records")
def donation_records(
    status: Optional[str] = None,
    db: Session = Depends(get_db),
    current_user: User = Depends(require_role("Administrator", "CSWS Main Office", "CMO Representative")),
):
    """Appendix H, Module 4.4 / 4.5: View donation records and monitor
    donation status (Administrator, CSWS Main Office, CMO)."""
    from api.v1.cmo_router import _rows
    query = db.query(PhysicalDonation)
    if status:
        query = query.filter(PhysicalDonation.status == status)
    donations = query.order_by(PhysicalDonation.donation_id.desc()).limit(300).all()
    users = {
        u.user_id: f"{u.first_name or ''} {u.last_name or ''}".strip() or u.email
        for u in db.query(User).filter(User.user_id.in_({d.user_id for d in donations if d.user_id})).all()
    }
    guests = {
        g.guest_donor_id: g.full_name
        for g in db.query(GuestDonor).filter(
            GuestDonor.guest_donor_id.in_({d.guest_donor_id for d in donations if d.guest_donor_id})
        ).all()
    }
    rows = _rows(db, donations)
    for row, d in zip(rows, donations):
        row["donor"] = users.get(d.user_id) if d.user_id else f"{guests.get(d.guest_donor_id, 'Guest')} (guest)"
        row["handover_method"] = d.handover_method
        row["created_at"] = d.created_at
    return rows
