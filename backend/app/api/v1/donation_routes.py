import uuid
import qrcode
import io
import base64
from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session

from core.database import get_db
from core.auth import get_current_user, get_current_user_optional
from models.user_rbac_model import User
from models.guest_donor_model import GuestDonor
from models.physical_donation_model import PhysicalDonation
from models.item_model import Item
from models.organization_model import Organization
from models.report import DisasterReport, DisasterType, Barangay
from schemas.physical_donation_schema import PhysicalDonationCreate, PhysicalDonationResponse
from core.notifications import notify_event, notify_event_many, user_ids_with_role

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

    item_id = payload.item_id
    if item_id is None:
        # "Other" item: reuse it if it already exists, else add it to the list.
        name = payload.other_item_name.strip()
        item = db.query(Item).filter(Item.item_name.ilike(name)).first()
        if item is None:
            item = Item(
                item_name=name,
                category="Other",
                unit_of_measure=(payload.other_item_unit or "pcs").strip() or "pcs",
            )
            db.add(item)
            db.flush()
        item_id = item.item_id
    elif db.get(Item, item_id) is None:
        raise HTTPException(status_code=404, detail="Item not found")

    qr_reference = f"DON-{uuid.uuid4().hex[:12].upper()}"

    donation = PhysicalDonation(
        user_id=current_user.user_id if current_user else None,
        guest_donor_id=guest_donor_id,
        report_id=payload.report_id,
        item_id=item_id,
        packaging=payload.packaging,
        quantity=payload.quantity,
        estimated_value=payload.estimated_value,
        handover_method=payload.handover_method,
        pickup_address=payload.pickup_address,
        qr_reference=qr_reference,
        status="Pending",
    )
    db.add(donation)
    db.flush()  # assigns donation_id for the notifications

    if current_user:  # guest donors have no account
        notify_event(db, current_user.user_id, "donation_submitted_confirm",
                     "donation", donation.donation_id, batch_no=donation.donation_id)
    notify_event_many(db, user_ids_with_role(db, ["CSWS Main Office"]),
                      "donation_submitted", None, None, batch_no=donation.donation_id)

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


@router.get("/mine")
def my_donations(
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    """Donor / Relief Organization dashboard (manuscript UC-D3, UC-D4,
    UC-R3, UC-R4): the user's own donation history and status, the reports
    they supported, and those reports' fulfillment progress."""
    donations = (
        db.query(PhysicalDonation)
        .filter(PhysicalDonation.user_id == current_user.user_id)
        .order_by(PhysicalDonation.donation_id.desc())
        .all()
    )
    items = {i.item_id: i for i in db.query(Item).all()}
    types = {t.disaster_type_id: t.type_name for t in db.query(DisasterType).all()}
    barangays = {b.barangay_id: b.barangay_name for b in db.query(Barangay).all()}
    report_ids = {d.report_id for d in donations}
    reports = {
        r.report_id: r
        for r in db.query(DisasterReport).filter(DisasterReport.report_id.in_(report_ids)).all()
    } if report_ids else {}

    def report_info(r):
        f = r.fulfillment
        return {
            "report_id": r.report_id,
            "label": f"{types.get(r.disaster_type_id, 'Disaster')} in {barangays.get(r.barangay_id, 'Barangay')}",
            "status": r.status,
            "priority_level": r.priority_level,
            "total_items_needed": f.total_items_needed if f else r.estimated_quantity,
            "total_items_delivered": f.total_items_delivered if f else 0,
            "fulfillment_percentage": float(f.fulfillment_percentage) if f else 0.0,
        }

    org = db.get(Organization, current_user.organization_id) if current_user.organization_id else None
    by_status = {}
    for d in donations:
        by_status[d.status] = by_status.get(d.status, 0) + 1

    return {
        "profile": {
            "name": f"{current_user.first_name} {current_user.last_name}".strip(),
            "email": current_user.email,
            "role": current_user.role.role_name,
            "organization": org.org_name if org else None,
            "account_status": org.status if org else "Active",
            # Door to Door: donors "select his/her address" (manuscript 3.1).
            "address": org.address if org else None,
        },
        "summary": {
            "total_donations": len(donations),
            "pending": by_status.get("Pending", 0),
            "received": by_status.get("Received", 0),
            "confirmed": by_status.get("Confirmed", 0),
            "total_quantity": sum(d.quantity for d in donations),
            "supported_reports": len(report_ids),
        },
        "donations": [
            {
                "donation_id": d.donation_id,
                "qr_reference": d.qr_reference,
                "item_name": items[d.item_id].item_name if d.item_id in items else "Item",
                "unit": items[d.item_id].unit_of_measure if d.item_id in items else "",
                "quantity": d.quantity,
                "packaging": d.packaging,
                "handover_method": d.handover_method,
                "pickup_address": d.pickup_address,
                "status": d.status,
                "created_at": d.created_at,
                "report": report_info(reports[d.report_id]) if d.report_id in reports else None,
            }
            for d in donations
        ],
        "supported_reports": [report_info(r) for r in reports.values()],
}