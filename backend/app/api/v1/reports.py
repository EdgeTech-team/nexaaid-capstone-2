"""
app/api/v1/reports.py

Module 3.4 — Report Management (Mariquit)

ASSUMPTION TO VERIFY: `require_role` and `get_current_user` are
imported from `app.core.auth`, which per the WBS notes is "already
built and usable" even though it hasn't been shown to me. I've
assumed the common FastAPI pattern:

    def get_current_user(...) -> User: ...          # Depends()
    def require_role(*roles: str):                   # Depends() factory
        def _checker(user: User = Depends(get_current_user)) -> User:
            if user.role not in roles: raise HTTPException(403)
            return user
        return _checker

If Castillo/Hoyohoy's real auth.py has a different shape (different
names, decorator instead of dependency, etc.), the fix is localized
to the two `Depends(...)` lines in each endpoint below — nothing else
needs to change.

Role names ("citizen", "csws_staff", "admin") are placeholders too —
swap them for whatever your actual RBAC role names are once 3.3 is
merged.

CHANGE LOG
- Concerns2.txt 2.1 (Castillo): tapping a "report validated" notification
  opens the report detail with the same UI, just elaborated. GET
  /reports/{report_id} now returns ReportMonitoringResponse (the report
  plus its fulfillment progress) instead of DisasterReportResponse.
  Additive only: every old field is unchanged, four fields were added.
  Row-building moved into _to_monitoring() so the detail, /monitoring and
  /validated endpoints all build the same shape.
- SMS reporting, manuscript-aligned (claude/sms-reporting-decision.md):
  * POST /reports/sms is Administrator-only (UC-A3 alt 8a, UC-CD1 alt
    11b, Scope 2.4: the Disaster Unit SENDS the SMS, the Administrator
    reviews and ENCODES it). Oct 12 it moved to the Disaster Unit (the
    Barangay Rep sent the SMS); Oct 15 (team) it is back to the manuscript.
  * The report is filed under the Disaster Unit member whose number sent
    the SMS, so they get the "validated" notice and can follow it.
  * Scope 2.4: when an SMS report is validated, every registered user is
    notified, not only the usual recipients.
"""

from typing import List, Optional

from fastapi import APIRouter, Depends, HTTPException, Query, Request, status
from sqlalchemy.orm import Session
from sqlalchemy.orm import joinedload
from datetime import datetime, timezone
from core.priority_engine import apply_priority
from services.fulfillment import progress as needs_progress, recalculate as recalculate_fulfillment, set_needs
from services.items import resolve_item_id

from core.database import get_db
from core.auth import get_current_user, get_current_user_optional, require_role, has_role, barangay_scope, can_view_unvalidated_report
from core.audit import log_action  # see note above
from models.report import DisasterReport, SmsReportMetadata, ReportFulfillment, canonical_source
from models.disaster_type_model import DisasterType, OTHER_DISASTER_TYPE
from models.sitio_model import Sitio
from core.notifications import notify, notify_event_many, user_ids_with_role
from schemas.report import (
    DisasterReportCreate,
    DisasterReportUpdate,
    DisasterReportResponse,
    SmsReportIngest,
    SmsReportIngestResponse,
    SmsReportMetadataResponse,
    ReportValidate,
    ReportReject,
    ReportMonitoringResponse,
    DisasterReportEdit,
    ReportWithdraw,
)

router = APIRouter(prefix="/reports", tags=["reports"])


# ---------------------------------------------------------------------------
# Shared by create_report and ingest_sms_report (J1): tell everyone who has to
# act on a new report. The Administrator is included because only admins can
# validate or reject; the submitter is excluded so they don't notify themselves.
# ---------------------------------------------------------------------------
def _notify_new_report(db: Session, report: DisasterReport, exclude_user_id: int) -> None:
    notify_event_many(
        db,
        user_ids_with_role(
            db,
            ["Administrator", "CSWS Main Office", "CSWS Disaster Unit"],
            exclude_user_id=exclude_user_id,
        ),
        "report_submitted", "report", report.report_id,
        title=f"Report #{report.report_id}",
    )


# ---------------------------------------------------------------------------
# Used by validate_report: once a report is validated, tell everyone affected.
#   - officials: CMO and both CSWS offices
#   - barangay representative(s) of the affected barangay only
#   - donors (individual and organization), because the report is now open
#     for donations
# The reporter gets their own message in validate_report, and the validating
# admin is skipped. Every recipient gets exactly one notification.
#
# The role_name strings below match the roles table exactly. If a role is
# ever renamed, update them here: a wrong name notifies nobody, silently.
# ---------------------------------------------------------------------------
def _notify_report_validated(db: Session, report: DisasterReport, validator_id: int) -> set[int]:
    skip = {report.user_id, validator_id}

    officials = set(user_ids_with_role(
        db, ["CMO Representative", "CSWS Main Office", "CSWS Disaster Unit"]
    )) - skip

    donors = set(user_ids_with_role(
        db, ["Individual Donor", "Relief Organization"]
    )) - skip

    # Never fall back to "all barangays": with no barangay on the report,
    # user_ids_with_role would skip the filter and notify every representative.
    brgy_reps: set[int] = set()
    if report.barangay_id is not None:
        brgy_reps = set(user_ids_with_role(
            db, ["Barangay Receiving Representative"], barangay_id=report.barangay_id
        )) - skip

    title = f"Report #{report.report_id}"
    notify_event_many(
        db, officials | brgy_reps, "report_validated",
        "report", report.report_id, title=title,
    )
    notify_event_many(
        db, donors, "report_open_for_donations",
        "report", report.report_id, title=title,
    )
    return officials | brgy_reps | donors


# Every role in the roles table (Scope 1). Used for Scope 2.4: "All
# registered users will automatically receive a push notification once an
# SMS report has been successfully encoded and validated."
ALL_ROLES = [
    "Administrator", "CSWS Disaster Unit", "CSWS Main Office",
    "CMO Representative", "DRRMO Logistics Support",
    "Barangay Receiving Representative", "Individual Donor",
    "Relief Organization",
]


def _notify_sms_validated_everyone(
    db: Session, report: DisasterReport, already: set[int]
) -> None:
    # No barangay filter here: Scope 2.4 says ALL registered users.
    rest = set(user_ids_with_role(db, ALL_ROLES)) - already
    notify_event_many(
        db, rest, "report_validated", "report", report.report_id,
        title=f"Report #{report.report_id}",
    )


# ---------------------------------------------------------------------------
# Shared response builder: report + fulfillment progress.
# Used by GET /reports/{id}, /reports/monitoring and /reports/validated.
# ---------------------------------------------------------------------------
def _to_monitoring(report: DisasterReport) -> ReportMonitoringResponse:
    fulfillment = report.fulfillment
    return ReportMonitoringResponse(
        **DisasterReportResponse.model_validate(report).model_dump(),
        fulfillment_status=fulfillment.verification_status if fulfillment else None,
        fulfillment_percentage=fulfillment.fulfillment_percentage if fulfillment else None,
        total_items_needed=fulfillment.total_items_needed if fulfillment else None,
        total_items_delivered=fulfillment.total_items_delivered if fulfillment else None,
    )


def _monitoring_rows(query, skip: int, limit: int):
    rows = (
        query.order_by(DisasterReport.created_at.desc())
        .offset(skip)
        .limit(limit)
        .all()
    )
    return [_to_monitoring(report) for report in rows]


# ---------------------------------------------------------------------------
# problema_napud 2.2: one or more sitios, all in the report's barangay.
# ---------------------------------------------------------------------------
def _apply_sitios(db: Session, report: DisasterReport, sitio_id, sitio_ids) -> None:
    ids = list(dict.fromkeys(
        sitio_ids if sitio_ids is not None else ([sitio_id] if sitio_id else [])
    ))
    found = {s.sitio_id: s for s in db.query(Sitio).filter(Sitio.sitio_id.in_(ids)).all()} if ids else {}
    wrong = [i for i in ids if i not in found or found[i].barangay_id != report.barangay_id]
    if wrong:
        raise HTTPException(
            status_code=422,
            detail="Choose sitios of the report's own barangay "
                   f"(not in this barangay: {', '.join(str(i) for i in wrong)})",
        )
    # Same order as DisasterReport.sitios, so sitio_id is always the first.
    ids.sort()
    report.sitios = [found[i] for i in ids]
    report.sitio_id = ids[0] if ids else None


def _apply_type_other(db: Session, report: DisasterReport, other) -> None:
    """A report of type "Other" says what kind of disaster it was (e.g.
    "Gas leak"); any other type clears it."""
    t = db.get(DisasterType, report.disaster_type_id)
    if t is not None and t.type_name == OTHER_DISASTER_TYPE:
        if not other:
            raise HTTPException(status_code=422, detail="Type what kind of disaster it was")
        report.disaster_type_other = other
    else:
        report.disaster_type_other = None


def _save_needs(db: Session, report: DisasterReport, needs, estimated_quantity) -> None:
    """Per-item needs (Oct 2026). needs = list from newer apps; without it
    estimated_quantity becomes one "General needs" line (older apps, SMS)."""
    set_needs(db, report, needs, estimated_quantity,
              lambda item_id, name, unit: resolve_item_id(db, item_id, name, unit))


def _needs_log(report: DisasterReport) -> list:
    return [{"item_id": n.item_id, "quantity": n.quantity} for n in report.needs]


# ---------------------------------------------------------------------------
# Create — any authenticated reporter (citizen / barangay official / staff)
# ---------------------------------------------------------------------------
@router.post("/", response_model=DisasterReportResponse, status_code=status.HTTP_201_CREATED)
def create_report(
    payload: DisasterReportCreate,
    db: Session = Depends(get_db),
    # Appendix H 2.1 / UC-CD1: only the CSWS Disaster Unit submits reports
    # (Oct 17 run-through: any logged-in account could before).
    current_user=Depends(require_role("csws_disaster_unit")),
):
    report = DisasterReport(
        **payload.model_dump(exclude={"sitio_ids", "needs"}), user_id=current_user.user_id
    )
    _apply_type_other(db, report, payload.disaster_type_other)
    _apply_sitios(db, report, payload.sitio_id, payload.sitio_ids)
    db.add(report)
    db.flush()   # get report.report_id before commit (commit happens in get_db)
    _save_needs(db, report, payload.needs, payload.estimated_quantity)
    db.refresh(report)

    _notify_new_report(db, report, current_user.user_id)
    return report


# ---------------------------------------------------------------------------
# List — staff only, with filters + pagination
# ---------------------------------------------------------------------------
@router.get("/", response_model=List[DisasterReportResponse])
def list_reports(
    status_filter: Optional[str] = Query(default=None, alias="status"),
    barangay_id: Optional[int] = Query(default=None),
    disaster_type_id: Optional[int] = Query(default=None),
    source: Optional[str] = Query(default=None),
    priority_level: Optional[str] = Query(default=None), # 3.7
    skip: int = Query(default=0, ge=0),
    limit: int = Query(default=50, ge=1, le=200),
    db: Session = Depends(get_db),
    current_user=Depends(require_role("csws_staff", "admin", "barangay_official")),
):
    query = db.query(DisasterReport).filter(DisasterReport.deleted_at.is_(None))
    own_barangay = barangay_scope(current_user)
    if own_barangay is not None:
        query = query.filter(DisasterReport.barangay_id == own_barangay)

    if status_filter:
        query = query.filter(DisasterReport.status == status_filter)
    if barangay_id:
        query = query.filter(DisasterReport.barangay_id == barangay_id)
    if disaster_type_id:
        query = query.filter(DisasterReport.disaster_type_id == disaster_type_id)
    if source:
        query = query.filter(DisasterReport.source == canonical_source(source))
    if priority_level:
        query = query.filter(DisasterReport.priority_level == priority_level) #3.7

    return (
        query.order_by(DisasterReport.created_at.desc())
        .offset(skip)
        .limit(limit)
        .all()
    )


@router.get("/monitoring", response_model=List[ReportMonitoringResponse])
def list_report_monitoring(
    barangay_id: Optional[int] = Query(default=None),
    disaster_type_id: Optional[int] = Query(default=None),
    status_filter: Optional[str] = Query(default=None, alias="status"),
    source: Optional[str] = Query(default=None),
    priority_level: Optional[str] = Query(default=None), # 3.7
    skip: int = Query(default=0, ge=0),
    limit: int = Query(default=50, ge=1, le=200),
    db: Session = Depends(get_db),
    current_user=Depends(require_role("csws_staff", "admin", "barangay_official")),
):
    query = (
        db.query(DisasterReport)
        .options(joinedload(DisasterReport.fulfillment))
        .filter(DisasterReport.deleted_at.is_(None))
    )
    own_barangay = barangay_scope(current_user)
    if own_barangay is not None:
        query = query.filter(DisasterReport.barangay_id == own_barangay)

    if status_filter:
        query = query.filter(DisasterReport.status == status_filter)
    if barangay_id:
        query = query.filter(DisasterReport.barangay_id == barangay_id)
    if disaster_type_id:
        query = query.filter(DisasterReport.disaster_type_id == disaster_type_id)
    if source:
        query = query.filter(DisasterReport.source == canonical_source(source))
    if priority_level:
        query = query.filter(DisasterReport.priority_level == priority_level) #3.7

    return _monitoring_rows(query, skip, limit)


# ---------------------------------------------------------------------------
# Appendix H, Module 2.4 / 3.3: every logged-in role views validated reports,
# filtered by priority level where the role has priority-based filtering.
# ---------------------------------------------------------------------------
@router.get("/validated", response_model=List[ReportMonitoringResponse])
def list_validated_reports(
    barangay_id: Optional[int] = Query(default=None),
    disaster_type_id: Optional[int] = Query(default=None),
    priority_level: Optional[str] = Query(default=None),
    skip: int = Query(default=0, ge=0),
    limit: int = Query(default=100, ge=1, le=200),
    db: Session = Depends(get_db),
    current_user=Depends(get_current_user),
):
    query = (
        db.query(DisasterReport)
        .options(joinedload(DisasterReport.fulfillment))
        .filter(DisasterReport.status == "Validated", DisasterReport.deleted_at.is_(None))
    )
    if barangay_id:
        query = query.filter(DisasterReport.barangay_id == barangay_id)
    if disaster_type_id:
        query = query.filter(DisasterReport.disaster_type_id == disaster_type_id)
    if priority_level:
        query = query.filter(DisasterReport.priority_level == priority_level)
    return _monitoring_rows(query, skip, limit)


# ---------------------------------------------------------------------------
# Oct 11 notes (Daniel): the CSWS Disaster Unit edits or withdraws its own
# report while the Administrator has not validated it yet (Pending, or
# Rejected and being corrected). A withdrawn report is kept as "Cancelled"
# for the record and can no longer be validated.
# ---------------------------------------------------------------------------
_EDITABLE_REPORT = ("Pending", "Rejected")


@router.get("/mine", response_model=List[ReportMonitoringResponse])
def my_reports(
    db: Session = Depends(get_db),
    current_user=Depends(get_current_user),
):
    """The reports this user submitted, newest first, with their status."""
    query = (
        db.query(DisasterReport)
        .options(joinedload(DisasterReport.fulfillment))
        .filter(DisasterReport.user_id == current_user.user_id,
                DisasterReport.deleted_at.is_(None))
    )
    return _monitoring_rows(query, 0, 200)


def _get_live_report(db: Session, report_id: int) -> DisasterReport:
    """The report, or 404 when it does not exist or was deleted (testing 2.3)."""
    report = db.get(DisasterReport, report_id)
    if not report or report.deleted_at is not None:
        raise HTTPException(status_code=404, detail="Report not found")
    return report


def _own_open_report(db: Session, report_id: int, user, action: str) -> DisasterReport:
    report = _get_live_report(db, report_id)
    if report.user_id != user.user_id:
        raise HTTPException(status_code=403, detail=f"You can only {action} reports you submitted")
    if report.status not in _EDITABLE_REPORT:
        done = {"edit": "edited", "withdraw": "withdrawn"}[action]
        raise HTTPException(
            status_code=409,
            detail=f"This report is already {report.status}, so it can no longer be {done}",
        )
    return report


@router.put("/{report_id}/mine", response_model=DisasterReportResponse)
def edit_my_report(
    report_id: int,
    payload: DisasterReportEdit,
    db: Session = Depends(get_db),
    current_user=Depends(get_current_user),
):
    """Correct a report before validation. A rejected report that is
    corrected goes back to the Administrator as Pending."""
    report = _own_open_report(db, report_id, current_user, "edit")
    fields = payload.model_dump(exclude={"needs"})
    before = {k: getattr(report, k) for k in fields}
    before["status"] = report.status
    before["needs"] = _needs_log(report)
    for field, value in payload.model_dump(exclude={"sitio_ids", "needs"}).items():
        setattr(report, field, value)
    _apply_type_other(db, report, payload.disaster_type_other)
    _apply_sitios(db, report, payload.sitio_id, payload.sitio_ids)
    _save_needs(db, report, payload.needs, payload.estimated_quantity)
    resubmitted = report.status == "Rejected"
    if resubmitted:
        report.status = "Pending"
        report.rejection_reason = None
        report.validated_by = None
    log_action(db, current_user, "EDIT REPORT", "disaster_reports", report.report_id,
               old={k: (v if k == "needs" else str(v) if v is not None else None) for k, v in before.items()},
               new={**{k: (str(v) if v is not None else None) for k, v in fields.items()},
                    "needs": _needs_log(report), "status": report.status})
    if resubmitted:
        # Back in the validation queue, so the Administrators hear about it.
        _notify_new_report(db, report, current_user.user_id)
    db.flush()
    db.refresh(report)
    return report


@router.post("/{report_id}/withdraw", response_model=DisasterReportResponse)
def withdraw_my_report(
    report_id: int,
    payload: Optional[ReportWithdraw] = None,
    db: Session = Depends(get_db),
    current_user=Depends(get_current_user),
):
    """The reporter cancels a report that is not validated. It is kept with
    status Cancelled (and leaves the validation queue); nothing is deleted."""
    report = _own_open_report(db, report_id, current_user, "withdraw")
    old = report.status
    report.status = "Cancelled"
    reason = (payload.reason or "").strip() if payload else ""
    log_action(db, current_user, "WITHDRAW REPORT", "disaster_reports", report.report_id,
               old={"status": old}, new={"status": "Cancelled", "reason": reason or None})
    # It leaves the Administrators' validation queue: tell them why it went.
    notify_event_many(db, user_ids_with_role(db, ["Administrator"]), "report_withdrawn",
                      "report", report.report_id, title=f"Report #{report.report_id}")
    db.flush()
    db.refresh(report)
    return report


# ---------------------------------------------------------------------------
# Retrieve one — also the target of every report notification tap
# (Concerns2.txt 2.1). Returns the report plus fulfillment progress so the
# detail screen can show the elaborated view.
# ---------------------------------------------------------------------------
@router.get("/{report_id}", response_model=ReportMonitoringResponse)
def get_report(
    report_id: int,
    db: Session = Depends(get_db),
    current_user=Depends(get_current_user),
):
    report = (
        db.query(DisasterReport)
        .options(joinedload(DisasterReport.fulfillment))
        .filter(DisasterReport.report_id == report_id,
                DisasterReport.deleted_at.is_(None))
        .first()
    )
    if not report:
        raise HTTPException(status_code=404, detail="Report not found")

      # Every logged-in role can open a validated report (same rule as GET
    # /reports/validated), so donors, the CMO and others can open it from
    # their notification. Any other status: core.auth.can_view_unvalidated_report
    # (F-05: a barangay rep only in its own barangay).
    if report.status != "Validated" and not can_view_unvalidated_report(current_user, report):
        raise HTTPException(status_code=403, detail="Not authorized to view this report")

    is_owner = report.user_id == current_user.user_id
    is_staff = has_role(current_user, "csws_staff", "admin", "barangay_official")
    is_validated = report.status == "Validated"
    if not (is_owner or is_staff or is_validated):
        raise HTTPException(status_code=403, detail="Not authorized to view this report")

    return _to_monitoring(report)


# ---------------------------------------------------------------------------
# Per-item fulfillment (Oct 2026): for every need of the report, how much is
# pledged, confirmed by the CMO ("in stock") and delivered (barangay
# receipt, the official figure), each capped at 100%. Validated reports
# are public like the rest of the transparency data; others follow the
# same rule as GET /reports/{id}.
# ---------------------------------------------------------------------------
@router.get("/{report_id}/needs")
def report_needs_progress(
    report_id: int,
    db: Session = Depends(get_db),
    current_user=Depends(get_current_user_optional),
):
    report = _get_live_report(db, report_id)
    if report.status != "Validated" and not can_view_unvalidated_report(current_user, report):
        raise HTTPException(status_code=404, detail="Report not found")   # F-05

    return needs_progress(db, report)


# ---------------------------------------------------------------------------
# Corrections — Administrator only (description, families, needs, ...).
# F-07: the status is not changed here (validate / reject / withdraw /
# delete do that, with their own checks, records and notices), and every
# correction is written to the audit log.
# ---------------------------------------------------------------------------
@router.patch("/{report_id}", response_model=DisasterReportResponse)
def update_report(
    report_id: int,
    payload: DisasterReportUpdate,
    db: Session = Depends(get_db),
    # Administrator only (Oct 17 run-through). Reporters correct reports
    # with PUT /{id}/mine.
    current_user=Depends(require_role("admin")),
):
    report = _get_live_report(db, report_id)

    updates = payload.model_dump(exclude_unset=True)
    needs = updates.pop("needs", None)
    old = {k: getattr(report, k) for k in updates}     # F-07: for the audit log
    old_needs = _needs_log(report)
    old_priority = report.priority_level
    for field, value in updates.items():
        setattr(report, field, value)

    # Per-item needs (Oct 2026). A needs list replaces them; a new
    # estimated_quantity alone only changes an older report's "General
    # needs" line (it is ignored when the report has per-item needs).
    needs_changed = False
    if needs is not None:
        _save_needs(db, report, payload.needs, None)
        needs_changed = True
    elif "estimated_quantity" in updates and all(n.item_id is None for n in report.needs):
        _save_needs(db, report, None, updates["estimated_quantity"])
        needs_changed = True

    # Weak spot 5: changing what the report needs (or its families / type)
    # after validation must move fulfillment and priority with it. Priority
    # itself cannot be set here (schemas/report.py, testing #5).
    affects_priority = needs_changed or {"affected_families", "disaster_type_id"} & set(updates)
    if report.status == "Validated" and affects_priority:
        if needs_changed and report.fulfillment is not None:
            recalculate_fulfillment(db, report.report_id, None)
            db.refresh(report)
        apply_priority(report)

    # F-07: who changed what, and what it was before.
    if updates or needs_changed:
        def plain(v):
            return str(v) if v is not None else None
        old_log = {k: plain(v) for k, v in old.items()}
        new_log = {k: plain(v) for k, v in updates.items()}
        if needs_changed:
            old_log["needs"], new_log["needs"] = old_needs, _needs_log(report)
        if report.priority_level != old_priority:
            old_log["priority_level"], new_log["priority_level"] = old_priority, report.priority_level
        log_action(db, current_user, "UPDATE REPORT", "disaster_reports", report.report_id,
                   old=old_log, new=new_log)

    db.flush()
    db.refresh(report)
    return report


# ---------------------------------------------------------------------------
# Validate — UC-02 step 6: admin approves, report becomes visible to donors
# ---------------------------------------------------------------------------
@router.post("/{report_id}/validate", response_model=DisasterReportResponse)
def validate_report(
    report_id: int,
    payload: Optional[ReportValidate] = None,
    db: Session = Depends(get_db),
    current_user=Depends(require_role("admin")),
):
    report = _get_live_report(db, report_id)
    if report.status == "Validated":
        raise HTTPException(status_code=400, detail="Report is already validated")
    if report.status == "Cancelled":
        raise HTTPException(status_code=409, detail="The reporter withdrew this report")
    # UC-A3 7a / priority module 1a: no priority guidance can be computed
    # without data, so the report is corrected first (reject it with a
    # reason; the Disaster Unit fixes it and it comes back).
    if not (report.affected_families or report.estimated_quantity or report.assistance_needed):
        raise HTTPException(
            status_code=422,
            detail="This report has no affected families, assistance needed or quantity, so "
                   "priority guidance cannot be computed. Reject it so the Disaster Unit can complete it.",
        )

    report.status = "Validated"
    report.validated_by = current_user.user_id
    report.rejection_reason = None

    existing_fulfillment = (
        db.query(ReportFulfillment)
        .filter(ReportFulfillment.report_id == report_id)
        .first()
    )

    if not existing_fulfillment:
        db.add(
            ReportFulfillment(
                report_id=report_id,
                total_items_needed=report.estimated_quantity or 0,
            )
        )

    # Flush so the newly-created fulfillment row is available
    # through report.fulfillment before priority is computed.
    db.flush()
    # Per-item needs: totals and percentage from report_needs (0% now).
    recalculate_fulfillment(db, report_id, None)
    db.refresh(report)

    apply_priority(report)
    log_action(db, current_user, "VALIDATE REPORT", "disaster_reports", report.report_id,
               old={"status": "Pending"},
               new={"status": "Validated", "priority_level": report.priority_level})

    # The reporter gets a personal message...
    notify(db, report.user_id, "report_validated",
           title=f"Report #{report.report_id} validated",
           body="Your report was approved and is now visible to donors.",
           entity_type="report", entity_id=report.report_id)

    # ...and everyone else affected: CMO, both CSWS offices, the barangay
    # representative of the affected barangay, and the donors.
    notified = _notify_report_validated(db, report, current_user.user_id)
    if report.source == "SMS":
        _notify_sms_validated_everyone(
            db, report, notified | {report.user_id, current_user.user_id}
        )

    db.flush()
    db.refresh(report)
    return report


# ---------------------------------------------------------------------------
# Reject — UC-02 extension 5a: admin rejects, rep gets specific feedback
# ---------------------------------------------------------------------------
@router.post("/{report_id}/reject", response_model=DisasterReportResponse)
def reject_report(
    report_id: int,
    payload: ReportReject,
    db: Session = Depends(get_db),
    current_user=Depends(require_role("admin")),
):
    report = _get_live_report(db, report_id)
    if report.status == "Cancelled":
        raise HTTPException(status_code=409, detail="The reporter withdrew this report")

    report.status = "Rejected"
    report.validated_by = current_user.user_id  # who made the rejection call
    report.rejection_reason = payload.rejection_reason
    log_action(db, current_user, "REJECT REPORT", "disaster_reports", report.report_id,
               new={"status": "Rejected", "reason": payload.rejection_reason})

    notify(db, report.user_id, "report_rejected",
           title=f"Report #{report.report_id} needs changes",
           body=f"Your report was rejected: {payload.rejection_reason}",
           entity_type="report", entity_id=report.report_id)

    db.flush()
    db.refresh(report)
    return report


# ---------------------------------------------------------------------------
# Delete — admin only, Rejected reports only (testing 2.3).
# A soft delete: the row stays (with who rejected it and why) so the audit
# trail survives, and every list and count hides it from now on.
# ---------------------------------------------------------------------------
@router.delete("/{report_id}", status_code=status.HTTP_204_NO_CONTENT)
def delete_report(
    report_id: int,
    request: Request,
    db: Session = Depends(get_db),
    current_user=Depends(require_role("admin")),
):
    report = _get_live_report(db, report_id)
    if report.status != "Rejected":
        raise HTTPException(
            status_code=409,
            detail=f"Only rejected reports can be deleted. This one is {report.status}.",
        )
    report.deleted_at = datetime.now(timezone.utc)
    report.deleted_by_user_id = current_user.user_id
    log_action(db, current_user, "DELETE REPORT", "disaster_reports", report.report_id,
               old={"status": report.status, "rejection_reason": report.rejection_reason},
               new={"deleted": True}, request=request)
    db.flush()
    return None


# ---------------------------------------------------------------------------
# SMS ingestion — the Administrator encodes an incoming SMS into report + metadata
# ---------------------------------------------------------------------------
def _phone_key(number: Optional[str]) -> str:
    """'+63 917-123-4567' and '09171234567' -> '9171234567'."""
    digits = "".join(ch for ch in (number or "") if ch.isdigit())
    return digits[-10:]


def _disaster_unit_member(db: Session, number: Optional[str]):
    """The active Disaster Unit member whose profile number sent the SMS,
    or None (the report is then filed under the encoding Administrator)."""
    from models.role_model import Role
    from models.user_rbac_model import User

    key = _phone_key(number)
    if len(key) < 10:
        return None
    rows = (
        db.query(User)
        .join(Role, Role.role_id == User.role_id)
        .filter(Role.role_name == "CSWS Disaster Unit", User.is_active.is_(True))
        .order_by(User.user_id)
        .all()
    )
    return next((u for u in rows if _phone_key(u.contact_number) == key), None)

@router.post(
    "/sms",
    response_model=SmsReportIngestResponse,
    status_code=status.HTTP_201_CREATED,
)
def ingest_sms_report(
    payload: SmsReportIngest,
    db: Session = Depends(get_db),
    # Scope 2.4, UC-A3 alt 8a, UC-CD1 alt 11b (Oct 15 team, back to the
    # manuscript): the CSWS Disaster Unit, offline, SENDS the structured SMS
    # to the Administrators; an Administrator reviews and ENCODES it here
    # (source "SMS"). It then waits in the validation queue as Pending.
    current_user=Depends(require_role("admin")),
):
    report_fields = payload.model_dump(exclude={"contact_number", "raw_message", "sitio_ids", "needs"})
    sender = _disaster_unit_member(db, payload.contact_number)
    report = DisasterReport(
        **report_fields,
        user_id=sender.user_id if sender else current_user.user_id,
        source="SMS",
    )
    _apply_type_other(db, report, payload.disaster_type_other)
    _apply_sitios(db, report, payload.sitio_id, payload.sitio_ids)
    db.add(report)
    db.flush()  # need report.report_id for the metadata FK
    _save_needs(db, report, payload.needs, payload.estimated_quantity)

    sms_meta = SmsReportMetadata(
        report_id=report.report_id,
        contact_number=payload.contact_number,
        raw_message=payload.raw_message,
        encoded_by_user_id=current_user.user_id,
    )
    db.add(sms_meta)
    db.flush()
    db.refresh(report)
    db.refresh(sms_meta)

    # The other Administrators and both CSWS offices hear of the new report.
    _notify_new_report(db, report, current_user.user_id)

    return SmsReportIngestResponse(report=report, sms_metadata=sms_meta)


# ---------------------------------------------------------------------------
# Get SMS metadata for a report
# ---------------------------------------------------------------------------
@router.get("/{report_id}/sms-metadata", response_model=SmsReportMetadataResponse)
def get_sms_metadata(
    report_id: int,
    db: Session = Depends(get_db),
    current_user=Depends(require_role("csws_disaster_unit", "admin")),
):
    meta = (
        db.query(SmsReportMetadata)
        .filter(SmsReportMetadata.report_id == report_id)
        .first()
    )
    if not meta:
        raise HTTPException(status_code=404, detail="No SMS metadata for this report")
    return meta