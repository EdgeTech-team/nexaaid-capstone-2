"""
api/v1/item_routes.py — new items waiting for review (security audit F-15).

A donor or guest can type an item that is not in the list ("Something
else" on the donate form). It is saved with pending_review = true: the
donation records it and CSWS sees it when the goods arrive, but it is in no
dropdown until CSWS Main Office (which manages the goods, manuscript 3.3)
or the Administrator approves it.

GET  /items/pending              the items waiting, oldest first
POST /items/{item_id}/approve    {"item_name": "..."} optional, to correct the name
POST /items/{item_id}/reject     kept on the donations that use it, never offered
"""
from typing import Optional

from fastapi import APIRouter, Depends, HTTPException, Request
from pydantic import BaseModel, Field
from sqlalchemy import func
from sqlalchemy.orm import Session

from core.audit import log_action
from core.auth import require_role
from core.database import get_db
from models.item_model import Item
from models.physical_donation_model import PhysicalDonation
from models.user_rbac_model import User

router = APIRouter(prefix="/items", tags=["items"])
REVIEWERS = ("CSWS Main Office", "Administrator")


class ApproveItem(BaseModel):
    item_name: Optional[str] = Field(default=None, max_length=150)


def _waiting(db: Session, item_id: int) -> Item:
    item = db.get(Item, item_id)
    if item is None or not item.pending_review or not item.active:
        raise HTTPException(status_code=404, detail="No such item is waiting for review.")
    return item


@router.get("/pending")
def pending_items(
    db: Session = Depends(get_db),
    user: User = Depends(require_role(*REVIEWERS)),
):
    rows = (
        db.query(Item, func.count(PhysicalDonation.donation_id))
        .outerjoin(PhysicalDonation, PhysicalDonation.item_id == Item.item_id)
        .filter(Item.pending_review.is_(True), Item.active.is_(True))
        .group_by(Item.item_id)
        .order_by(Item.created_at, Item.item_id)
        .all()
    )
    return [
        {"item_id": i.item_id, "item_name": i.item_name, "unit": i.unit_of_measure,
         "created_at": i.created_at, "donation_lines": n}
        for i, n in rows
    ]


@router.post("/{item_id}/approve")
def approve_item(
    item_id: int,
    payload: ApproveItem,
    request: Request,
    db: Session = Depends(get_db),
    user: User = Depends(require_role(*REVIEWERS)),
):
    item = _waiting(db, item_id)
    old = {"item_name": item.item_name, "pending_review": True}
    name = (payload.item_name or "").strip()
    if name and name != item.item_name:
        if len(name) < 2:
            raise HTTPException(status_code=422, detail="Enter a name of at least 2 characters.")
        clash = (db.query(Item)
                 .filter(func.lower(Item.item_name) == name.lower(), Item.item_id != item.item_id)
                 .first())
        if clash is not None:
            raise HTTPException(
                status_code=409,
                detail=f'"{clash.item_name}" already exists. Choose another name, or reject this item.',
            )
        item.item_name = name
    item.pending_review = False
    log_action(db, user, "APPROVE ITEM", "items", item.item_id, old=old,
               new={"item_name": item.item_name, "pending_review": False}, request=request)
    db.flush()
    return {"item_id": item.item_id, "item_name": item.item_name, "pending_review": False}


@router.post("/{item_id}/reject")
def reject_item(
    item_id: int,
    request: Request,
    db: Session = Depends(get_db),
    user: User = Depends(require_role(*REVIEWERS)),
):
    item = _waiting(db, item_id)
    # Retired like an old item: the donations that use it keep it, but it is
    # never offered again.
    item.pending_review = False
    item.active = False
    log_action(db, user, "REJECT ITEM", "items", item.item_id,
               old={"item_name": item.item_name, "pending_review": True},
               new={"active": False}, request=request)
    db.flush()
    return {"item_id": item.item_id, "item_name": item.item_name, "active": False}
