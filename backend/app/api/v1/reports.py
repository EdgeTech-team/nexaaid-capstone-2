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
  * POST /reports/sms is now Administrator-only (UC-A3 alt 8a, UC-CD1 alt
    11b, Scope 2.4: the Disaster Unit SENDS the SMS, the Administrator
    reviews and ENCODES it). Was CSWS Disaster Unit.
  * Scope 2.4: when an SMS report is validated, every registered user is
    notified, not only the usual recipients.
"""

from typing import List, Optional

from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy.orm import Session
from sqlalchemy.orm import joinedload
from datetime import datetime, timezone
from core.priority_engine import compute_priority

from core.database import get_db
from core.auth import get_current_user, require_role, has_role, barangay_scope
from core.audit import log_action  # see note above
from models.report import DisasterReport, SmsReportMetadata, ReportFulfillment, canonical_source
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
# Create — any authenticated reporter (citizen / barangay official / staff)
# ---------------------------------------------------------------------------
@router.post("/", response_model=DisasterReportResponse, status_code=status.HTTP_201_CREATED)
def create_report(
    payload: DisasterReportCreate,
    db: Session = Depends(get_db),
    current_user=Depends(get_current_user),
):
    report = DisasterReport(**payload.model_dump(), user_id=current_user.user_id)
    db.add(report)
    db.flush()   # get report.report_id before commit (commit happens in get_db)
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
    query = db.query(DisasterReport)
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
    query = db.query(DisasterReport).options(joinedload(DisasterReport.fulfillment))
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
        .filter(DisasterReport.status == "Validated")
    )
    if barangay_id:
        query = query.filter(DisasterReport.barangay_id == barangay_id)
    if disaster_type_id:
        query = query.filter(DisasterReport.disaster_type_id == disaster_type_id)
    if priority_level:
        query = query.filter(DisasterReport.priority_level == priority_level)
    return _monitoring_rows(query, skip, limit)


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
        .filter(DisasterReport.report_id == report_id)
        .first()
    )
    if not report:
        raise HTTPException(status_code=404, detail="Report not found")

    # Reporters can see their own report; staff can see any; every logged-in
    # role can open a validated report (same rule as GET /reports/validated),
    # so donors, the CMO and others can open it from their notification.
    is_owner = report.user_id == current_user.user_id
    is_staff = has_role(current_user, "csws_staff", "admin", "barangay_official")
    is_validated = report.status == "Validated"
    if not (is_owner or is_staff or is_validated):
        raise HTTPException(status_code=403, detail="Not authorized to view this report")

    return _to_monitoring(report)


# ---------------------------------------------------------------------------
# Update — staff only (status, priority, AI fields, corrections)
# ---------------------------------------------------------------------------
@router.patch("/{report_id}", response_model=DisasterReportResponse)
def update_report(
    report_id: int,
    payload: DisasterReportUpdate,
    db: Session = Depends(get_db),
    current_user=Depends(require_role("csws_staff", "admin")),
):
    report = db.get(DisasterReport, report_id)
    if not report:
        raise HTTPException(status_code=404, detail="Report not found")

    updates = payload.model_dump(exclude_unset=True)
    for field, value in updates.items():
        setattr(report, field, value)

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
    report = db.get(DisasterReport, report_id)
    if not report:
        raise HTTPException(status_code=404, detail="Report not found")
    if report.status == "Validated":
        raise HTTPException(status_code=400, detail="Report is already validated")

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
    db.refresh(report)

    priority_result = compute_priority(report)

    VALID_LEVELS = ("Low", "Medium", "High", "Critical")
    level = priority_result["priority_level"]

    report.ai_priority_score = priority_result["score"]
    # "Needs Review" / "Review Required" violate chk_disaster_reports_priority,
    # so store NULL and keep the reason in ai_recommendation.
    report.priority_level = level if level in VALID_LEVELS else None
    report.ai_recommendation = priority_result["recommendation"]
    report.ai_processed_at = datetime.now(timezone.utc)
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
    report = db.get(DisasterReport, report_id)
    if not report:
        raise HTTPException(status_code=404, detail="Report not found")

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
# Delete — admin only
# ---------------------------------------------------------------------------
@router.delete("/{report_id}", status_code=status.HTTP_204_NO_CONTENT)
def delete_report(
    report_id: int,
    db: Session = Depends(get_db),
    current_user=Depends(require_role("admin")),
):
    report = db.get(DisasterReport, report_id)
    if not report:
        raise HTTPException(status_code=404, detail="Report not found")
    db.delete(report)
    return None


# ---------------------------------------------------------------------------
# SMS ingestion — staff encodes an incoming SMS into report + metadata
# ---------------------------------------------------------------------------
@router.post(
    "/sms",
    response_model=SmsReportIngestResponse,
    status_code=status.HTTP_201_CREATED,
)
def ingest_sms_report(
    payload: SmsReportIngest,
    db: Session = Depends(get_db),
    # UC-A3 alt 8a / Scope 2.4: the CSWS Disaster Unit SENDS the SMS; the
    # Administrator reviews and manually ENCODES it here.
    current_user=Depends(require_role("admin")),
):
    report_fields = payload.model_dump(exclude={"contact_number", "raw_message"})
    report = DisasterReport(**report_fields, user_id=current_user.user_id, source="SMS")
    db.add(report)
    db.flush()  # need report.report_id for the metadata FK

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