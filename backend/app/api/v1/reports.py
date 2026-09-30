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
"""

from typing import List, Optional

from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy.orm import Session
from sqlalchemy.orm import joinedload
from datetime import datetime, timezone
from core.priority_engine import compute_priority

from core.database import get_db
from core.auth import get_current_user, require_role, has_role  # see note above
from models.report import DisasterReport, SmsReportMetadata, ReportFulfillment
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

   
    if status_filter:
        query = query.filter(DisasterReport.status == status_filter)
    if barangay_id:
        query = query.filter(DisasterReport.barangay_id == barangay_id)
    if disaster_type_id:
        query = query.filter(DisasterReport.disaster_type_id == disaster_type_id)
    if source:
        query = query.filter(DisasterReport.source == source)
    if priority_level:
        query = query.filter(DisasterReport.priority_level == priority_level) #3.7

    
    return (
        query.order_by(DisasterReport.created_at.desc())
        .offset(skip)
        .limit(limit)
        .all()
    )

@router.get("/monitoring",
            response_model=List[ReportMonitoringResponse],)
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

    if status_filter:
            query = query.filter(DisasterReport.status == status_filter)
    if barangay_id:
            query = query.filter(DisasterReport.barangay_id == barangay_id)
    if disaster_type_id:
            query = query.filter(DisasterReport.disaster_type_id == disaster_type_id)
    if source:
            query = query.filter(DisasterReport.source == source)
    if priority_level:
            query = query.filter(DisasterReport.priority_level == priority_level) #3.7

    results = []
    for report in (
         query.order_by(DisasterReport.created_at.desc())
         .offset(skip)
         .limit(limit)
         .all()                 
         ):
            fulfillment = report.fulfillment
            results.append(ReportMonitoringResponse(
                **DisasterReportResponse.model_validate(report).model_dump(),
                fulfillment_status=(
                    fulfillment.verification_status
                    if fulfillment
                    else None
                ),
                fulfillment_percentage=(
                    fulfillment.fulfillment_percentage
                    if fulfillment
                    else None
                ),
                total_items_needed=(
                    fulfillment.total_items_needed
                    if fulfillment
                    else None
                ),
                total_items_delivered=(
                    fulfillment.total_items_delivered
                    if fulfillment
                    else None
                ),

            ))
    return results

# ---------------------------------------------------------------------------
# Retrieve one
# ---------------------------------------------------------------------------
@router.get("/{report_id}", response_model=DisasterReportResponse)
def get_report(
    report_id: int,
    db: Session = Depends(get_db),
    current_user=Depends(get_current_user),
):
    report = db.get(DisasterReport, report_id)
    if not report:
        raise HTTPException(status_code=404, detail="Report not found")

    # Reporters can see their own report; staff can see any.
    is_owner = report.user_id == current_user.user_id
    is_staff = has_role(current_user, "csws_staff", "admin", "barangay_official")
    if not (is_owner or is_staff):
        raise HTTPException(status_code=403, detail="Not authorized to view this report")

    return report


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
    payload: ReportValidate,
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

    report.ai_priority_score = priority_result["score"]
    report.priority_level = priority_result["priority_level"]
    report.ai_recommendation = priority_result["recommendation"]
    report.ai_processed_at = datetime.now(timezone.utc)

    db.flush()
    db.refresh(report)

    # TODO: notify the submitting Barangay Representative + publish to
    # donor/org-facing GET endpoint, per UC-02 step 7 / SD4 Phase 3.
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

    db.flush()
    db.refresh(report)
    # TODO: notify the submitting Barangay Representative with
    # rejection_reason so they can correct and resubmit (UC-02 5a).
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
    current_user=Depends(require_role("csws_staff", "admin")),
):
    report_fields = payload.model_dump(exclude={"contact_number", "raw_message"})
    report = DisasterReport(**report_fields, user_id=current_user.user_id, source="sms")
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

    return SmsReportIngestResponse(report=report, sms_metadata=sms_meta)


# ---------------------------------------------------------------------------
# Get SMS metadata for a report
# ---------------------------------------------------------------------------
@router.get("/{report_id}/sms-metadata", response_model=SmsReportMetadataResponse)
def get_sms_metadata(
    report_id: int,
    db: Session = Depends(get_db),
    current_user=Depends(require_role("csws_staff", "admin")),
):
    meta = (
        db.query(SmsReportMetadata)
        .filter(SmsReportMetadata.report_id == report_id)
        .first()
    )
    if not meta:
        raise HTTPException(status_code=404, detail="No SMS metadata for this report")
    return meta