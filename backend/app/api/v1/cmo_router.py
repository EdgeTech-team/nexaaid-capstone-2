# routers/cmo_router.py
from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy.orm import Session
from core.database import get_db
from core.auth import require_role
from models.user_rbac_model import User
from models.physical_donation_model import PhysicalDonation
from models.donation_confirmation_model import DonationConfirmation
from schemas.donation_confirmation_schema import ConfirmDonationRequest, DonationConfirmationResponse

router = APIRouter(prefix="/cmo", tags=["cmo"])

@router.post("/donations/{donation_id}/confirm", response_model=DonationConfirmationResponse, status_code=status.HTTP_201_CREATED)
def confirm_donation(
    donation_id: int,
    payload: ConfirmDonationRequest,
    db: Session = Depends(get_db),
    current_user: User = Depends(require_role("CMO Representative")),
):
    donation = db.query(PhysicalDonation).filter(PhysicalDonation.donation_id == donation_id).first()
    if donation is None:
        raise HTTPException(status_code=404, detail="Donation not found")

    if donation.status == "Confirmed":
        raise HTTPException(status_code=400, detail="Donation is already confirmed")

    confirmation = DonationConfirmation(
        donation_id=donation_id,
        confirmed_by_user_id=current_user.user_id,
        status=payload.status,
        notes=payload.notes,
    )
    db.add(confirmation)

    if payload.status == "Confirmed":
        donation.status = "Confirmed"

    db.commit()
    db.refresh(confirmation)
    return confirmation

@router.get("/donations/pending")
def list_pending_donations(
    db: Session = Depends(get_db),
    current_user: User = Depends(require_role("CMO Representative")),
):
    donations = db.query(PhysicalDonation).filter(PhysicalDonation.status == "Received").all()
    return donations


@router.get("/dashboard")
def cmo_dashboard(
    db: Session = Depends(get_db),
    current_user: User = Depends(require_role("CMO Representative")),
):
    pending = db.query(PhysicalDonation).filter(PhysicalDonation.status == "Received").count()
    confirmed = db.query(PhysicalDonation).filter(PhysicalDonation.status == "Confirmed").count()
    return {"pending_confirmation": pending, "confirmed": confirmed}