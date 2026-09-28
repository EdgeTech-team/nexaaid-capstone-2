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

from typing import Optional
from pydantic import BaseModel
from models.item_model import Item
from datetime import datetime

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
    report_id: int
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
    query = db.query(Inventory, Item.item_name).join(Item, Inventory.item_id == Item.item_id)
    if report_id is not None:
        query = query.filter(Inventory.report_id == report_id)

    results = query.all()
    return [
        InventoryResponse(
            inventory_id=inv.inventory_id,
            item_id=inv.item_id,
            item_name=item_name,
            report_id=inv.report_id,
            quantity=inv.quantity,
            last_updated=inv.last_updated,
        )
        for inv, item_name in results
    ]


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
    db.commit()
    db.refresh(donation)
    return donation