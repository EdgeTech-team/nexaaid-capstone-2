# routers/cmo_router.py
# Manuscript UC-C1 / UC-C2 and the City Confirmation Module.
from datetime import datetime, timedelta, timezone
from types import SimpleNamespace
from typing import Optional

from fastapi import APIRouter, Depends, HTTPException, Response, status
from sqlalchemy import String, case, exists, func, literal, or_, select
from sqlalchemy.orm import Session, aliased
from core.shared.pagination import PageParams, paginate_query, set_total_header
from core.shared.database import get_db
from core.m1_user_management.auth import require_role
from core.shared.audit import log_action
from core.m1_user_management.user_rbac_model import User
from core.reference_data.item_model import Item
from core.m4_donation_management.physical_donation_model import PhysicalDonation
from core.m6_city_confirmation.donation_confirmation_model import DonationConfirmation
from core.m4_donation_management.guest_donor_model import GuestDonor
from core.m5_inventory.received_goods_model import ReceivedGoods
from core.m2_disaster_reporting.report_model import DisasterReport, DisasterType, Barangay, ReportFulfillment
from core.m6_city_confirmation.donation_confirmation_schema import ConfirmDonationRequest, DonationConfirmationResponse
from core.notifications.notifications import notify_event, notify_event_many, user_ids_with_role


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
        r.report_id: f"#{r.report_id} {r.disaster_label(types)} - {brgys.get(r.barangay_id, 'Barangay')}"
        for r in db.query(DisasterReport).filter(DisasterReport.report_id.in_(report_ids)).all()
    }


def _rows(db: Session, donations) -> list:
    items = {i.item_id: i for i in db.query(Item).all()}
    decisions = _latest_decisions(db, [d.donation_id for d in donations])
    labels = _report_labels(db, {d.report_id for d in donations})
    # G-002 (D8): what CSWS counted, next to what the donor declared.
    from core.m5_inventory.received_goods_model import ReceivedGoods
    from core.reference_data.item_quantities import donated_item_fields
    counted = {g.donation_id: g.actual_quantity for g in db.query(ReceivedGoods).filter(
        ReceivedGoods.donation_id.in_([d.donation_id for d in donations] or [-1])).all()}
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
            **donated_item_fields(d, it.unit_of_measure if it else "", counted.get(d.donation_id)),
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


# ---------------------------------------------------------------------------
# Task #10 (M6, Oct 23): a CMO acknowledgement is FINAL. There is no undo,
# in the app or the API (the old POST /cmo/entries/{ref}/revert and
# /cmo/donations/{id}/revert are removed). Reason: acknowledged goods move on
# to Main Office's deliveries and the dashboards; a silent rollback would
# break the audit trail and could leave a delivery holding goods that are no
# longer acknowledged. Before acknowledging, the CMO can still put an entry
# On Hold or keep it for Review, each with a logged reason.
#
# Task #11: "Confirm" and "Acknowledge" are one action. Both words are
# stored as the single status "Confirmed" (physical_donations.status) with
# one timestamp (donation_confirmations.confirmed_at). There is no separate
# acknowledged status, so nothing can sit "confirmed but not acknowledged".
# ---------------------------------------------------------------------------
@router.post("/donations/{donation_id}/confirm", response_model=DonationConfirmationResponse, status_code=status.HTTP_201_CREATED)
def confirm_donation(
    donation_id: int,
    payload: ConfirmDonationRequest,
    db: Session = Depends(get_db),
    current_user: User = Depends(require_role(CMO)),
):
    """One item. The app now acknowledges whole entries (below); this stays
    for older clients and tests. Acknowledging is final (task #10)."""
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


def _iso(v: Optional[datetime]) -> Optional[str]:
    if v is None:
        return None
    return (v.replace(tzinfo=timezone.utc) if v.tzinfo is None else v).isoformat()


def _entry_context(db: Session, donations) -> dict:
    """What the CMO cards show besides the items (Oct 23 CMO redesign):
    disaster type and barangay of the report, the donor's name (no phone:
    donors are told only CSWS staff see it), when CSWS received the goods
    and when the CMO acknowledged them."""
    ids = [d.donation_id for d in donations]
    if not ids:
        return {"reports": {}, "received": {}, "acknowledged": {}, "donors": {}}
    types = {t.disaster_type_id: t.type_name for t in db.query(DisasterType).all()}
    brgys = {b.barangay_id: b.barangay_name for b in db.query(Barangay).all()}
    reports = {
        r.report_id: (r.disaster_label(types, None), brgys.get(r.barangay_id))
        for r in db.query(DisasterReport)
        .filter(DisasterReport.report_id.in_({d.report_id for d in donations})).all()
    }
    received = {
        g.donation_id: g.received_at
        for g in db.query(ReceivedGoods).filter(ReceivedGoods.donation_id.in_(ids)).all()
    }
    acknowledged: dict = {}
    for c in (db.query(DonationConfirmation)
              .filter(DonationConfirmation.donation_id.in_(ids),
                      DonationConfirmation.status == "Confirmed")
              .order_by(DonationConfirmation.confirmation_id).all()):
        acknowledged[c.donation_id] = c.confirmed_at
    donors: dict = {}
    users = {u.user_id: u for u in db.query(User).filter(
        User.user_id.in_({d.user_id for d in donations if d.user_id})).all()}
    guests = {g.guest_donor_id: g for g in db.query(GuestDonor).filter(
        GuestDonor.guest_donor_id.in_({d.guest_donor_id for d in donations
                                       if d.guest_donor_id})).all()}
    for d in donations:
        if d.user_id and d.user_id in users:
            u = users[d.user_id]
            donors[d.donation_id] = f"{u.first_name} {u.last_name}".strip() or "Donor"
        elif d.guest_donor_id and d.guest_donor_id in guests:
            donors[d.donation_id] = f"{guests[d.guest_donor_id].full_name} (guest)"
        else:
            donors[d.donation_id] = "Donor"
    return {"reports": reports, "received": received,
            "acknowledged": acknowledged, "donors": donors}


def _latest(values) -> Optional[datetime]:
    vals = [v.replace(tzinfo=timezone.utc) if v.tzinfo is None else v for v in values if v]
    return max(vals) if vals else None


def _entry_rows(db: Session, donations) -> list:
    """Items grouped into entries (one per QR) for the CMO screen."""
    items = _rows(db, donations)
    ctx = _entry_context(db, donations)
    by_ref: dict = {}
    for d, row in zip(donations, items):
        by_ref.setdefault(d.batch_reference or d.qr_reference, (d, []))[1].append(row)
    out = []
    for ref, (first, rows) in by_ref.items():
        decisions = {r["cmo_decision"] for r in rows if r["status"] == "Received"}
        holds = [r["hold_reason"] for r in rows if r["hold_reason"]]
        disaster, barangay = ctx["reports"].get(first.report_id, (None, None))
        ids = [r["donation_id"] for r in rows]
        out.append({
            "batch_reference": ref,
            "report_id": first.report_id,
            "report_label": rows[0]["report_label"],
            "disaster_type": disaster,
            "barangay": barangay,
            "donor": ctx["donors"].get(first.donation_id, "Donor"),
            "received_at": _iso(_latest(ctx["received"].get(i) for i in ids)),
            "acknowledged_at": _iso(_latest(ctx["acknowledged"].get(i) for i in ids)),
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
    response: Response,
    q: Optional[str] = None,
    disaster_type_id: Optional[int] = None,
    barangay_id: Optional[int] = None,
    on_hold: Optional[bool] = None,
    newest: bool = True,
    page: PageParams = Depends(),
    db: Session = Depends(get_db),
    current_user: User = Depends(require_role(CMO)),
):
    """Entries with items CSWS received that wait for the CMO (incl. on hold
    / under review), newest first.

    NF-003 (Module 6.1), all optional: q (QR reference, item, donor,
    barangay, disaster or report), disaster_type_id, barangay_id, on_hold
    (true = only On Hold, false = all but On Hold), newest (sort by when CSWS
    received them) and limit / offset (X-Total-Count). With any of them the
    database filters, sorts and pages; without them the answer is as before."""
    if _wants_sql_paging(page, q, disaster_type_id, barangay_id, on_hold, newest):
        rows, total = _entry_page(db, "Received", page=page, q=q,
                                  disaster_type_id=disaster_type_id,
                                  barangay_id=barangay_id, on_hold=on_hold, newest=newest)
        set_total_header(response, page, total)
        return rows
    donations = (db.query(PhysicalDonation)
                 .filter(PhysicalDonation.status == "Received")
                 .order_by(PhysicalDonation.donation_id.desc()).all())
    return _entry_rows(db, donations)


@router.get("/entries/acknowledged")
def acknowledged_entries(
    response: Response,
    q: Optional[str] = None,
    disaster_type_id: Optional[int] = None,
    barangay_id: Optional[int] = None,
    newest: bool = True,
    page: PageParams = Depends(),
    db: Session = Depends(get_db),
    current_user: User = Depends(require_role(CMO)),
):
    """The CMO's History (Module 6.1). NF-003, all optional: q,
    disaster_type_id, barangay_id, newest (sort by when they were
    acknowledged) and limit / offset (X-Total-Count), filtered, sorted and
    paged in the database. Without them the answer is as before."""
    if _wants_sql_paging(page, q, disaster_type_id, barangay_id, None, newest):
        rows, total = _entry_page(db, "Confirmed", page=page, q=q,
                                  disaster_type_id=disaster_type_id,
                                  barangay_id=barangay_id, on_hold=None, newest=newest)
        set_total_header(response, page, total)
        return rows
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
    one donation entry. The donor's status follows by itself. Acknowledging
    is final: an acknowledged entry is never waiting again (task #10)."""
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
    # Oct 23 redesign: the CMO's home shows today's work, not an all-time
    # total. Entries whose acknowledgement happened today (Philippine time).
    manila = timezone(timedelta(hours=8))
    start = datetime.now(manila).replace(hour=0, minute=0, second=0, microsecond=0)
    today_ids = {
        c.donation_id
        for c in db.query(DonationConfirmation).filter(
            DonationConfirmation.status == "Confirmed",
            DonationConfirmation.donation_id.in_([d.donation_id for d in confirmed] or [0]),
        ).all()
        # SQLite (tests) hands back naive UTC, Postgres aware: compare in Python.
        if c.confirmed_at and _latest([c.confirmed_at]) >= start
    }
    return {
        "acknowledged_today_entries": len({d.batch_reference for d in confirmed
                                           if d.donation_id in today_ids}),
        "needs_review_entries": len({d.batch_reference for d in pending
                                     if not (decisions.get(d.donation_id) and
                                             decisions[d.donation_id].status == "On Hold")}),
        "pending_entries": entries(pending),
        "on_hold_entries": entries(pending, "On Hold"),
        "review_entries": entries(pending, "Pending Review"),
        "acknowledged_entries": entries(confirmed),
        "pending_confirmation": len(pending),
        "on_hold": sum(1 for d in pending if decisions.get(d.donation_id) and decisions[d.donation_id].status == "On Hold"),
        # NF-003: entries (not items) on hold, for the "On hold" tile, so the app
        # no longer downloads the whole queue to count them.
        "on_hold_entries": _entry_page(db, "Received", page=_COUNT_ONLY, q=None,
                                       disaster_type_id=None, barangay_id=None,
                                       on_hold=True, newest=True)[1],
        "pending_review": sum(1 for d in pending if decisions.get(d.donation_id) and decisions[d.donation_id].status == "Pending Review"),
        "confirmed": len(confirmed),
        "per_report": per_report,
}

# ---------------------------------------------------------------------------
# NF-001 / NF-003 (Module 6.3): donation summaries per report, one page at a
# time and filtered by disaster type, grouped in SQL. GET /cmo/dashboard keeps
# its per_report list as it was (CMO dashboard, installed APKs).
# ---------------------------------------------------------------------------


@router.get("/report-summaries")
def report_summaries(
    response: Response,
    disaster_type_id: Optional[int] = None,
    page: PageParams = Depends(),
    db: Session = Depends(get_db),
    current_user: User = Depends(require_role(CMO, "Administrator")),
):
    """Appendix H 6.3 View donation summaries per report (CMO, Administrator).

    The same numbers as GET /cmo/dashboard's per_report, newest report first:
    received items waiting for the CMO (pending_count), acknowledged items
    with their quantity and estimated value, and the report's fulfillment.
    Optional disaster_type_id (an unknown id gives an empty list) and
    limit / offset (X-Total-Count holds the number of reports)."""
    pd = PhysicalDonation
    confirmed = pd.status == "Confirmed"
    query = (
        db.query(
            pd.report_id.label("report_id"),
            func.sum(case((pd.status == "Received", 1), else_=0)).label("pending_count"),
            func.sum(case((confirmed, 1), else_=0)).label("confirmed_count"),
            func.sum(case((confirmed, pd.quantity), else_=0)).label("confirmed_quantity"),
            func.sum(case((confirmed, func.coalesce(pd.estimated_value, 0)), else_=0))
            .label("confirmed_value"),
        )
        .filter(pd.status.in_(["Received", "Confirmed"]))
    )
    if disaster_type_id is not None:
        query = (query.join(DisasterReport, DisasterReport.report_id == pd.report_id)
                 .filter(DisasterReport.disaster_type_id == disaster_type_id))
    query = query.group_by(pd.report_id)
    rows, total = paginate_query(query, page, pd.report_id.desc())
    set_total_header(response, page, total)

    ids = [r.report_id for r in rows]
    labels = _report_labels(db, ids)
    fulfillment = {
        f.report_id: float(f.fulfillment_percentage)
        for f in db.query(ReportFulfillment).filter(ReportFulfillment.report_id.in_(ids or [-1]))
    }
    return [{
        "report_id": r.report_id,
        "report_label": labels.get(r.report_id),
        "pending_count": int(r.pending_count or 0),
        "confirmed_count": int(r.confirmed_count or 0),
        "confirmed_quantity": int(r.confirmed_quantity or 0),
        "confirmed_value": float(r.confirmed_value or 0),
        "fulfillment_percentage": fulfillment.get(r.report_id, 0.0),
    } for r in rows]


# ---------------------------------------------------------------------------
# NF-003 (Module 6.1): the CMO's queue, On hold and History lists, filtered,
# sorted and paged in SQL. The rows are still built by _entry_rows, so every
# field is the same as in the old full answer.
# ---------------------------------------------------------------------------
# A "page" of no rows: _entry_page then only counts.
_COUNT_ONLY = SimpleNamespace(requested=True, offset=0, limit=0)


def _wants_sql_paging(page, q, disaster_type_id, barangay_id, on_hold, newest) -> bool:
    return (page.requested or bool(q and q.strip()) or disaster_type_id is not None
            or barangay_id is not None or on_hold is not None or newest is False)


def _like(text: str) -> str:
    escaped = text.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")
    return f"%{escaped}%"


def _entry_page(db: Session, status: str, *, page, q, disaster_type_id, barangay_id,
                on_hold, newest) -> tuple:
    """Entries (one per QR) whose items have this status ("Received": the
    queue, "Confirmed": History), as _entry_rows builds them.

    Time: when CSWS received them (queue) or when the CMO acknowledged them
    (History); entries without one sort last, then by the newest item."""
    pd = PhysicalDonation
    if status == "Received":
        when = (select(func.max(ReceivedGoods.received_at))
                .where(ReceivedGoods.donation_id == pd.donation_id).scalar_subquery())
    else:
        when = (select(func.max(DonationConfirmation.confirmed_at))
                .where(DonationConfirmation.donation_id == pd.donation_id,
                       DonationConfirmation.status == "Confirmed").scalar_subquery())
    g = (db.query(
            pd.batch_reference.label("ref"),
            func.max(pd.donation_id).label("last_id"),
            func.min(pd.report_id).label("report_id"),
            func.max(when).label("at"),
        )
        .filter(pd.status == status)
        .group_by(pd.batch_reference)
        .subquery())

    query = db.query(g.c.ref)
    if disaster_type_id is not None or barangay_id is not None:
        query = query.join(DisasterReport, DisasterReport.report_id == g.c.report_id)
        if disaster_type_id is not None:
            query = query.filter(DisasterReport.disaster_type_id == disaster_type_id)
        if barangay_id is not None:
            query = query.filter(DisasterReport.barangay_id == barangay_id)
    if on_hold is not None:
        held = _all_on_hold(g)
        query = query.filter(held if on_hold else ~held)
    if q and q.strip():
        query = query.filter(_cmo_search(g, q.strip().lower(), status))

    total = query.count()
    order = (g.c.at.is_(None).asc(),
             g.c.at.desc() if newest else g.c.at.asc(),
             g.c.last_id.desc() if newest else g.c.last_id.asc())
    query = query.order_by(*order)
    if page.requested:
        query = query.offset(page.offset).limit(page.limit)
    refs = [ref for (ref,) in query.all()]
    if not refs:
        return [], total
    donations = (db.query(pd).filter(pd.batch_reference.in_(refs), pd.status == status)
                 .order_by(pd.donation_id.desc()).all())
    built = {e["batch_reference"]: e for e in _entry_rows(db, donations)}
    return [built[ref] for ref in refs if ref in built], total


def _all_on_hold(g):
    """_entry_rows' cmo_decision == "On Hold": the latest decision of every
    received item of the entry is On Hold."""
    row = aliased(PhysicalDonation)
    latest = aliased(DonationConfirmation)
    decision = (select(latest.status).where(latest.donation_id == row.donation_id)
                .order_by(latest.confirmation_id.desc()).limit(1).scalar_subquery())
    return ~exists().where(
        row.batch_reference == g.c.ref, row.status == "Received",
        or_(decision.is_(None), decision != "On Hold"))


def _cmo_search(g, text: str, status: str):
    """The CMO screens' search: QR reference, donor, barangay, disaster type,
    report ("#12 Flood - Tipolo") or an item name."""
    pattern = _like(text)
    row = aliased(PhysicalDonation)
    item_row = aliased(PhysicalDonation)
    report = aliased(DisasterReport)
    dtype = aliased(DisasterType)
    brgy = aliased(Barangay)
    user = aliased(User)
    guest = aliased(GuestDonor)
    name = func.trim(func.coalesce(user.first_name, "") + " " + func.coalesce(user.last_name, ""))
    label = (literal("#") + func.cast(report.report_id, String) + " "
             + func.coalesce(dtype.type_name, "Disaster") + " - "
             + func.coalesce(brgy.barangay_name, "Barangay"))
    return or_(
        func.lower(g.c.ref).like(pattern, escape="\\"),
        exists().where(
            report.report_id == g.c.report_id,
            dtype.disaster_type_id == report.disaster_type_id,
            brgy.barangay_id == report.barangay_id,
            func.lower(label).like(pattern, escape="\\")),
        exists().where(
            item_row.batch_reference == g.c.ref, item_row.status == status,
            Item.item_id == item_row.item_id,
            func.lower(Item.item_name).like(pattern, escape="\\")),
        exists().where(
            row.donation_id == g.c.last_id, user.user_id == row.user_id,
            func.lower(name).like(pattern, escape="\\")),
        exists().where(
            row.donation_id == g.c.last_id, guest.guest_donor_id == row.guest_donor_id,
            func.lower(func.coalesce(guest.full_name, "") + " (guest)").like(pattern, escape="\\")),
    )
