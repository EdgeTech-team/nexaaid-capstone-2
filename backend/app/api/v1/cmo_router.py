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
from core.notifications import notify_event, notify_event_many, user_ids_with_role


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
            "hold_reason": dec.notes if dec and dec.status == "On Hold" else None, 
            "officially_recognized": d.status == "Confirmed",
        })
    return out


def _decide(db: Session, user: User, donation: PhysicalDonation, decision: str,
            notes) -> DonationConfirmation:
    """Record one CMO decision on one received item (no notification)."""
    confirmation = DonationConfirmation(
        donation_id=donation.donation_id,
        confirmed_by_user_id=user.user_id,
        status=decision,
        notes=notes,
    )
    db.add(confirmation)
    if decision == "Confirmed":
        donation.status = "Confirmed"
    db.flush()
    log_action(db, user, f"CMO {decision.upper()}", "physical_donations", donation.donation_id,
               old={"status": "Received"}, new={"status": donation.status, "decision": decision,
                                               "notes": notes})
    return confirmation


def _tell_donor(db: Session, donation: PhysicalDonation, decision: str, notes) -> None:
    # Daniel (Oct 10): the donor hears about the whole donation entry, in
    # order: submitted -> received by CSWS -> acknowledged by the CMO. One
    # "acknowledged" notice per entry, sent when its last received item is
    # acknowledged (not one per item).
    if not donation.user_id:  # guests have no account
        return
    ref = donation.batch_reference or donation.qr_reference
    if decision == "Confirmed":
        waiting = (db.query(PhysicalDonation)
                   .filter(PhysicalDonation.batch_reference == donation.batch_reference,
                           PhysicalDonation.status == "Received")
                   .count())
        if waiting == 0:
            notify_event(db, donation.user_id, "donation_confirmed", "donation",
                         donation.donation_id, batch_no=ref)
    elif decision == "On Hold":
        notify_event(db, donation.user_id, "donation_held", "donation",
                     donation.donation_id, batch_no=ref, reason=notes or "")


def _tell_main_office(db: Session, donation: PhysicalDonation, decision: str, notes) -> None:
    # Oct 17 (Mark): CSWS Main Office hears when the CMO acknowledges a
    # donation entry (it can now go on a delivery), or puts it on hold. One
    # notice per entry, like the donor's.
    ref = donation.batch_reference or donation.qr_reference
    report = _report_labels(db, [donation.report_id]).get(donation.report_id, "")
    if decision == "Confirmed":
        waiting = (db.query(PhysicalDonation)
                   .filter(PhysicalDonation.batch_reference == donation.batch_reference,
                           PhysicalDonation.status == "Received")
                   .count()) if donation.batch_reference else 0
        if waiting:
            return
        event = "donation_ready_for_delivery"
    elif decision == "On Hold":
        event = "donation_held_staff"
    else:
        return
    notify_event_many(db, user_ids_with_role(db, ["CSWS Main Office"]), event, "donation",
                      donation.donation_id, batch_no=ref, report=report, reason=notes or "")


def _not_on_a_delivery(db: Session, rows) -> None:
    """Oct 17 run-through: once acknowledged goods are on a delivery (not
    cancelled), the acknowledgement cannot be undone; cancel the delivery
    first. Otherwise the entry would wait for the CMO again while its goods
    are already on the road, or delivered."""
    from models.delivery import Delivery, DeliveryAllocation, DeliveryItem
    hit = (
        db.query(Delivery.delivery_id)
        .join(DeliveryItem, DeliveryItem.delivery_id == Delivery.delivery_id)
        .join(DeliveryAllocation, DeliveryAllocation.delivery_item_id == DeliveryItem.delivery_item_id)
        .filter(DeliveryAllocation.donation_id.in_([r.donation_id for r in rows]),
                Delivery.status != "Cancelled")
        .first()
    )
    if hit:
        raise HTTPException(
            status_code=409,
            detail=f"This donation is already on delivery #{hit[0]}, so its acknowledgement cannot "
                   "be undone. Main Office can cancel that delivery first.",
        )


def _tell_undone(db: Session, donation: PhysicalDonation) -> None:
    """The donor and CSWS Main Office were told it was acknowledged; tell
    them it is not any more."""
    ref = donation.batch_reference or donation.qr_reference
    if donation.user_id:
        notify_event(db, donation.user_id, "donation_unacknowledged", "donation",
                     donation.donation_id, batch_no=ref)
    report = _report_labels(db, [donation.report_id]).get(donation.report_id, "")
    notify_event_many(db, user_ids_with_role(db, ["CSWS Main Office"]), "donation_unacknowledged_staff",
                      "donation", donation.donation_id, batch_no=ref, report=report)


@router.post("/donations/{donation_id}/confirm", response_model=DonationConfirmationResponse, status_code=status.HTTP_201_CREATED)
def confirm_donation(
    donation_id: int,
    payload: ConfirmDonationRequest,
    db: Session = Depends(get_db),
    current_user: User = Depends(require_role(CMO)),
):
    """One item. The app now acknowledges whole entries (below); this stays
    for older clients and tests."""
    donation = db.query(PhysicalDonation).filter(PhysicalDonation.donation_id == donation_id).first()
    if donation is None:
        raise HTTPException(status_code=404, detail="Donation not found")

    if donation.status == "Confirmed":
        raise HTTPException(status_code=400, detail="Donation is already acknowledged")
    if donation.status != "Received":
        # UC-C1 precondition: only goods CSWS has actually received
        raise HTTPException(status_code=400, detail="Only donations received by CSWS can be acknowledged")

    confirmation = _decide(db, current_user, donation, payload.status, payload.notes)
    _tell_donor(db, donation, payload.status, payload.notes)
    _tell_main_office(db, donation, payload.status, payload.notes)
    db.commit()
    db.refresh(confirmation)
    return confirmation


# ---------------------------------------------------------------------------
# Oct 11 notes (Dave): the CMO acknowledges by donation entry (one QR), not
# per item. Every item of the entry that CSWS received gets the decision at
# once; items still waiting to be handed over are left alone.
# ---------------------------------------------------------------------------
def _entry(db: Session, reference: str) -> list:
    ref = reference.strip().upper()
    rows = (db.query(PhysicalDonation)
            .filter((PhysicalDonation.batch_reference == ref) | (PhysicalDonation.qr_reference == ref))
            .first())
    if rows is None:
        raise HTTPException(status_code=404, detail=f"No donation entry {reference}")
    return (db.query(PhysicalDonation)
            .filter(PhysicalDonation.batch_reference == rows.batch_reference)
            .order_by(PhysicalDonation.donation_id).all())


def _entry_rows(db: Session, donations) -> list:
    """Items grouped into entries (one per QR) for the CMO screen."""
    items = _rows(db, donations)
    by_ref: dict = {}
    for d, row in zip(donations, items):
        by_ref.setdefault(d.batch_reference or d.qr_reference, (d, []))[1].append(row)
    out = []
    for ref, (first, rows) in by_ref.items():
        decisions = {r["cmo_decision"] for r in rows if r["status"] == "Received"}
        holds = [r["hold_reason"] for r in rows if r["hold_reason"]]
        out.append({
            "batch_reference": ref,
            "report_id": first.report_id,
            "report_label": rows[0]["report_label"],
            "handover_method": first.handover_method,
            "total_items": len(rows),
            "total_quantity": sum(r["quantity"] for r in rows),
            "estimated_value": float(sum((r["estimated_value"] or 0) for r in rows)),
            # One decision for the entry while it waits; "Acknowledged" once done.
            "cmo_decision": (next(iter(decisions)) if len(decisions) == 1 else
                             ("Mixed" if decisions else None)),
            "hold_reason": holds[0] if holds else None,
            "acknowledged": all(r["status"] == "Confirmed" for r in rows),
            "items": rows,
        })
    return out


class EntryDecision(ConfirmDonationRequest):
    pass


@router.get("/entries/pending")
def pending_entries(
    db: Session = Depends(get_db),
    current_user: User = Depends(require_role(CMO)),
):
    """Entries with items CSWS received that wait for the CMO (incl. on hold
    / under review), newest first."""
    donations = (db.query(PhysicalDonation)
                 .filter(PhysicalDonation.status == "Received")
                 .order_by(PhysicalDonation.donation_id.desc()).all())
    return _entry_rows(db, donations)


@router.get("/entries/acknowledged")
def acknowledged_entries(
    db: Session = Depends(get_db),
    current_user: User = Depends(require_role(CMO)),
):
    donations = (db.query(PhysicalDonation)
                 .filter(PhysicalDonation.status == "Confirmed")
                 .order_by(PhysicalDonation.donation_id.desc()).all())
    return _entry_rows(db, donations)


@router.get("/entries/by-donation/{donation_id}")
def entry_of_donation(
    donation_id: int,
    db: Session = Depends(get_db),
    current_user: User = Depends(require_role(CMO)),
):
    """problema_napud 4.1: the whole entry a CMO notification points at
    ("Donation ... was received by CSWS"), shown in a pop-out with
    Acknowledge and Close. Only items CSWS already received are listed."""
    d = db.get(PhysicalDonation, donation_id)
    if d is None:
        raise HTTPException(status_code=404, detail="Donation not found")
    rows = _entry(db, d.batch_reference) if d.batch_reference else [d]
    received = [r for r in rows if r.status in ("Received", "Confirmed")]
    if not received:
        raise HTTPException(status_code=404, detail="CSWS has not received this donation yet.")
    return _entry_rows(db, received)[0]


@router.post("/entries/{reference}/decide")
def decide_entry(
    reference: str,
    payload: EntryDecision,
    db: Session = Depends(get_db),
    current_user: User = Depends(require_role(CMO)),
):
    """Acknowledge (or put on hold / keep for review) every received item of
    one donation entry. The donor's status follows by itself."""
    rows = _entry(db, reference)
    received = [r for r in rows if r.status == "Received"]
    if not received:
        raise HTTPException(
            status_code=409,
            detail="Nothing to acknowledge: CSWS has not received this donation yet, "
                   "or it is already acknowledged.",
        )
    for r in received:
        _decide(db, current_user, r, payload.status, payload.notes)
    _tell_donor(db, received[0], payload.status, payload.notes)
    _tell_main_office(db, received[0], payload.status, payload.notes)
    db.commit()
    return {
        "batch_reference": rows[0].batch_reference,
        "decision": payload.status,
        "items": len(received),
        "acknowledged": all(r.status == "Confirmed" for r in rows),
    }


@router.post("/entries/{reference}/revert")
def revert_entry(
    reference: str,
    db: Session = Depends(get_db),
    current_user: User = Depends(require_role(CMO)),
):
    """Undo an acknowledgement for the whole entry (alt flow 4a)."""
    rows = [r for r in _entry(db, reference) if r.status == "Confirmed"]
    if not rows:
        raise HTTPException(status_code=409, detail="This donation entry is not acknowledged.")
    _not_on_a_delivery(db, rows)
    for r in rows:
        r.status = "Received"
        log_action(db, current_user, "CMO REVERT CONFIRMATION", "physical_donations", r.donation_id,
                   old={"status": "Confirmed"}, new={"status": "Received"})
    _tell_undone(db, rows[0])
    db.commit()
    return {"batch_reference": rows[0].batch_reference, "items": len(rows)}


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
        raise HTTPException(status_code=400, detail="Only acknowledged donations can be reverted")
    _not_on_a_delivery(db, [donation])
    donation.status = "Received"
    log_action(db, current_user, "CMO REVERT CONFIRMATION", "physical_donations", donation_id,
               old={"status": "Confirmed"}, new={"status": "Received"})
    _tell_undone(db, donation)
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
    # Oct 11: the CMO works by donation entry, so the counts are entries too.
    def entries(rows, decision=None):
        refs = {d.batch_reference for d in rows
                if decision is None or (decisions.get(d.donation_id) and
                                        decisions[d.donation_id].status == decision)}
        return len(refs)
    return {
        "pending_entries": entries(pending),
        "on_hold_entries": entries(pending, "On Hold"),
        "review_entries": entries(pending, "Pending Review"),
        "acknowledged_entries": entries(confirmed),
        "pending_confirmation": len(pending),
        "on_hold": sum(1 for d in pending if decisions.get(d.donation_id) and decisions[d.donation_id].status == "On Hold"),
        "pending_review": sum(1 for d in pending if decisions.get(d.donation_id) and decisions[d.donation_id].status == "Pending Review"),
        "confirmed": len(confirmed),
        "per_report": per_report,
}