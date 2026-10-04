# routers/cmo_router.py
# Manuscript UC-C1 / UC-C2 and the City Confirmation Module.
from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy.orm import Session
from core.database import get_db
from core.auth import require_role
from core.audit import log_action
from models.user_rbac_model import User
from models.item_model import Item
from models.physical_donation_model import PhysicalDonation
from models.donation_confirmation_model import DonationConfirmation
from models.report import DisasterReport, DisasterType, Barangay
from schemas.donation_confirmation_schema import ConfirmDonationRequest, DonationConfirmationResponse
from core.notifications import notify_event


router = APIRouter(prefix="/cmo", tags=["cmo"])

CMO = "CMO Representative"


def _latest_decisions(db: Session, donation_ids) -> dict:
    """donation_id -> latest CMO decision row (Confirmed / On Hold / Pending Review)."""
    if not donation_ids:
        return {}
    latest = {}
    rows = (
        db.query(DonationConfirmation)
        .filter(DonationConfirmation.donation_id.in_(donation_ids))
        .order_by(DonationConfirmation.confirmation_id)
        .all()
    )
    for row in rows:
        latest[row.donation_id] = row
    return latest


def _report_labels(db: Session, report_ids) -> dict:
    if not report_ids:
        return {}
    types = {t.disaster_type_id: t.type_name for t in db.query(DisasterType).all()}
    brgys = {b.barangay_id: b.barangay_name for b in db.query(Barangay).all()}
    return {
        r.report_id: f"#{r.report_id} {types.get(r.disaster_type_id, 'Disaster')} - {brgys.get(r.barangay_id, 'Barangay')}"
        for r in db.query(DisasterReport).filter(DisasterReport.report_id.in_(report_ids)).all()
    }


def _rows(db: Session, donations) -> list:
    items = {i.item_id: i for i in db.query(Item).all()}
    decisions = _latest_decisions(db, [d.donation_id for d in donations])
    labels = _report_labels(db, {d.report_id for d in donations})
    out = []
    for d in donations:
        dec = decisions.get(d.donation_id)
        it = items.get(d.item_id)
        out.append({
            "donation_id": d.donation_id,
            "qr_reference": d.qr_reference,
            "status": d.status,
            "item_id": d.item_id,
            "item_name": it.item_name if it else "Item",
            "unit": it.unit_of_measure if it else "",
            "quantity": d.quantity,
            "packaging": d.packaging,
            "estimated_value": d.estimated_value,
            "report_id": d.report_id,
            "report_label": labels.get(d.report_id),
            # Official recognition tag, or the CMO's last decision if not confirmed
            "cmo_decision": dec.status if dec else None,
            "cmo_notes": dec.notes if dec else None,
            "officially_recognized": d.status == "Confirmed",
        })
    return out


@router.post("/donations/{donation_id}/confirm", response_model=DonationConfirmationResponse, status_code=status.HTTP_201_CREATED)
def confirm_donation(
    donation_id: int,
    payload: ConfirmDonationRequest,
    db: Session = Depends(get_db),
    current_user: User = Depends(require_role(CMO)),
):
    donation = db.query(PhysicalDonation).filter(PhysicalDonation.donation_id == donation_id).first()
    if donation is None:
        raise HTTPException(status_code=404, detail="Donation not found")

    if donation.status == "Confirmed":
        raise HTTPException(status_code=400, detail="Donation is already confirmed")
    if donation.status != "Received":
        # UC-C1 precondition: only goods CSWS has actually received
        raise HTTPException(status_code=400, detail="Only donations received by CSWS can be confirmed")

    confirmation = DonationConfirmation(
        donation_id=donation_id,
        confirmed_by_user_id=current_user.user_id,
        status=payload.status,
        notes=payload.notes,
    )
    db.add(confirmation)

    if payload.status == "Confirmed":
        donation.status = "Confirmed"

    db.flush()
    log_action(db, current_user, f"CMO {payload.status.upper()}", "physical_donations", donation_id,
               old={"status": "Received"}, new={"status": donation.status, "decision": payload.status,
                                               "notes": payload.notes})
    if donation.user_id:  # guests have no account
        if payload.status == "Confirmed":
            notify_event(db, donation.user_id, "donation_confirmed", "donation",
                         donation_id, batch_no=donation_id)
        elif payload.status == "On Hold":
            notify_event(db, donation.user_id, "donation_held", "donation",
                         donation_id, batch_no=donation_id, reason=payload.notes or "")
    db.commit()
    db.refresh(confirmation)
    return confirmation


@router.post("/donations/{donation_id}/revert")
def revert_confirmation(
    donation_id: int,
    db: Session = Depends(get_db),
    current_user: User = Depends(require_role(CMO)),
):
    """City Confirmation Module alt flow 4a: reversing a confirmation removes
    the official recognition tag and returns the record to pending."""
    donation = db.get(PhysicalDonation, donation_id)
    if donation is None:
        raise HTTPException(status_code=404, detail="Donation not found")
    if donation.status != "Confirmed":
        raise HTTPException(status_code=400, detail="Only confirmed donations can be reverted")
    donation.status = "Received"
    log_action(db, current_user, "CMO REVERT CONFIRMATION", "physical_donations", donation_id,
               old={"status": "Confirmed"}, new={"status": "Received"})
    db.commit()
    return {"donation_id": donation_id, "status": donation.status}


@router.get("/donations/pending")
def list_pending_donations(
    db: Session = Depends(get_db),
    current_user: User = Depends(require_role(CMO)),
):
    """Received by CSWS, waiting for city confirmation (incl. held / under review)."""
    donations = (
        db.query(PhysicalDonation)
        .filter(PhysicalDonation.status == "Received")
        .order_by(PhysicalDonation.donation_id.desc())
        .all()
    )
    return _rows(db, donations)


@router.get("/donations/confirmed")
def list_confirmed_donations(
    db: Session = Depends(get_db),
    current_user: User = Depends(require_role(CMO)),
):
    donations = (
        db.query(PhysicalDonation)
        .filter(PhysicalDonation.status == "Confirmed")
        .order_by(PhysicalDonation.donation_id.desc())
        .all()
    )
    return _rows(db, donations)


@router.get("/dashboard")
def cmo_dashboard(
    db: Session = Depends(get_db),
    # Appendix H, Module 6.3: Admin also views donation summaries per report.
    current_user: User = Depends(require_role(CMO, "Administrator")),
):
    """UC-C2: pending, confirmed, and donation summaries per report."""
    donations = db.query(PhysicalDonation).filter(
        PhysicalDonation.status.in_(["Received", "Confirmed"])
    ).all()
    decisions = _latest_decisions(db, [d.donation_id for d in donations])
    pending = [d for d in donations if d.status == "Received"]
    confirmed = [d for d in donations if d.status == "Confirmed"]
    labels = _report_labels(db, {d.report_id for d in donations})
    reports = db.query(DisasterReport).filter(DisasterReport.report_id.in_(labels.keys())).all() if labels else []
    per_report = []
    for r in reports:
        mine = [d for d in donations if d.report_id == r.report_id]
        f = r.fulfillment
        per_report.append({
            "report_id": r.report_id,
            "report_label": labels.get(r.report_id),
            "pending_count": sum(1 for d in mine if d.status == "Received"),
            "confirmed_count": sum(1 for d in mine if d.status == "Confirmed"),
            "confirmed_quantity": sum(d.quantity for d in mine if d.status == "Confirmed"),
            "confirmed_value": float(sum((d.estimated_value or 0) for d in mine if d.status == "Confirmed")),
            "fulfillment_percentage": float(f.fulfillment_percentage) if f else 0.0,
        })
    return {
        "pending_confirmation": len(pending),
        "on_hold": sum(1 for d in pending if decisions.get(d.donation_id) and decisions[d.donation_id].status == "On Hold"),
        "pending_review": sum(1 for d in pending if decisions.get(d.donation_id) and decisions[d.donation_id].status == "Pending Review"),
        "confirmed": len(confirmed),
        "per_report": per_report,
}