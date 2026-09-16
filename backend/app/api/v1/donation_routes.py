import uuid
import qrcode
import io
import base64
from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session

from core.database import get_db
from core.auth import get_current_user_optional
from models.user_rbac_model import User
from models.guest_donor_model import GuestDonor
from models.physical_donation_model import PhysicalDonation
from schemas.physical_donation_schema import PhysicalDonationCreate, PhysicalDonationResponse

router = APIRouter(prefix="/donations", tags=["Physical Donations"])


@router.post("/", response_model=PhysicalDonationResponse)
def create_donation(
    payload: PhysicalDonationCreate,
    db: Session = Depends(get_db),
    current_user: User | None = Depends(get_current_user_optional),
):
    if current_user is None and payload.guest_donor is None:
        raise HTTPException(
            status_code=400,
            detail="Log in, or provide guest_donor details to donate anonymously.",
        )

    guest_donor_id = None
    if current_user is None:
        guest = GuestDonor(
            full_name=payload.guest_donor.full_name,
            contact_number=payload.guest_donor.contact_number,
            email=payload.guest_donor.email,
        )
        db.add(guest)
        db.flush()  # assigns guest.guest_donor_id without committing yet
        guest_donor_id = guest.guest_donor_id

    qr_reference = f"DON-{uuid.uuid4().hex[:12].upper()}"

    donation = PhysicalDonation(
        user_id=current_user.user_id if current_user else None,
        guest_donor_id=guest_donor_id,
        report_id=payload.report_id,
        item_id=payload.item_id,
        packaging=payload.packaging,
        quantity=payload.quantity,
        estimated_value=payload.estimated_value,
        handover_method=payload.handover_method,
        pickup_address=payload.pickup_address,
        qr_reference=qr_reference,
        status="Pending",
    )
    db.add(donation)
    db.commit()
    db.refresh(donation)
    return donation


@router.get("/{donation_id}/qr")
def get_donation_qr(donation_id: int, db: Session = Depends(get_db)):
    donation = db.query(PhysicalDonation).filter(PhysicalDonation.donation_id == donation_id).first()
    if not donation:
        raise HTTPException(status_code=404, detail="Donation not found")

    img = qrcode.make(donation.qr_reference)
    buffer = io.BytesIO()
    img.save(buffer, format="PNG")
    encoded = base64.b64encode(buffer.getvalue()).decode()
    return {"qr_reference": donation.qr_reference, "qr_image_base64": encoded}