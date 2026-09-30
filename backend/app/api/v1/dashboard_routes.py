from fastapi import APIRouter, Depends
from sqlalchemy import func
from sqlalchemy.orm import Session

from core.database import get_db
from core.auth import require_role
from models.report import DisasterReport, ReportFulfillment
from models.physical_donation_model import PhysicalDonation
from models.organization_model import Organization
from models.delivery import Delivery as delivery
from models.logistics_request_model import LogisticsRequest
from schemas.dashboard_schema import (    DashboardSummary, ReportsBreakdown, FulfillmentOverview, LogisticsOverview,
    StatusCount, PriorityCount,
)

router = APIRouter(prefix="/dashboard", tags=["dashboard"])

DASHBOARD_ROLES = ("admin", "csws_staff", "barangay_official")

@router.get("/summary", response_model=DashboardSummary)
def get_dashboard_summary(
    db: Session = Depends(get_db),
    user=Depends(require_role(*DASHBOARD_ROLES)),
):

    return DashboardSummary(
        total_reports=db.query(func.count(DisasterReport.report_id)).scalar() or 0,
        total_donations=db.query(func.count(PhysicalDonation.donation_id)).scalar() or 0,
        total_deliveries=db.query(func.count(delivery.delivery_id)).scalar() or 0,
        total_logistics_requests=db.query(func.count(LogisticsRequest.request_id)).scalar() or 0,
        active_organizations=db.query(func.count(Organization.organization_id))
            .filter(Organization.status == "Approved").scalar() or 0,
    )

@router.get("/reports-breakdown", response_model=ReportsBreakdown)
def get_reports_breakdown(
    db: Session = Depends(get_db),
    user=Depends(require_role(*DASHBOARD_ROLES)),
):
    by_status = (
        db.query(DisasterReport.status, func.count(DisasterReport.report_id))
        .group_by(DisasterReport.status)
        .all()

    )
    by_priority = (
        db.query(DisasterReport.priority_level, func.count(DisasterReport.report_id))
        .group_by(DisasterReport.priority_level)
        .all()
    )

    total_value = db.query(func.coalesce(func.sum(PhysicalDonation.estimated_value), 0)).scalar() or 0
    return ReportsBreakdown(
        by_status=[StatusCount(status=status, count=count) for status, count in by_status],
        by_priority=[PriorityCount(priority_level=p, count=c) for p, c in by_priority],
        total_estimated_value=float (total_value or 0),
    )

@router.get("/fulfillment", response_model=FulfillmentOverview)
def get_fulfillment_overview(
    db:Session = Depends(get_db),
    user=Depends (require_role(*DASHBOARD_ROLES))

):
    avg_pct = db.query(func.coalesce(func.avg(ReportFulfillment.fulfillment_percentage), 0)).scalar() or 0
    verified = db.query(func.count(ReportFulfillment.fulfillment_id)).filter(ReportFulfillment.verification_status == "Complete").scalar() or 0
    pending = db.query(func.count(ReportFulfillment.fulfillment_id)).filter(ReportFulfillment.verification_status.in_(["Not Started", "Partial"])).scalar() or 0
    return FulfillmentOverview(
        average_fulfillment_percentage=float(avg_pct or 0),
        fully_verified_count=verified,
        pending_verification_count=pending,
    )

@router.get("/logistics", response_model = LogisticsOverview)
def get_logistics_overview(
    db:Session = Depends(get_db),
    user=Depends(require_role(*DASHBOARD_ROLES)),

):
    requests = (
        db.query(LogisticsRequest.status, func.count(LogisticsRequest.request_id))
        .group_by(LogisticsRequest.status)
        .all()
    )
    deliveries = (
        db.query(delivery.status, func.count(delivery.delivery_id))
        .group_by(delivery.status)
        .all()
    )
    return LogisticsOverview(
        deliveries_by_status=[StatusCount(status=s, count=c) for s, c in deliveries],
        requests_by_status=[StatusCount(status=s, count=c) for s, c in requests],
    )
