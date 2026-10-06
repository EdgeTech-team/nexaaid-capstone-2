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


# ---------------------------------------------------------------------------
# Role-specific dashboards (manuscript section 7: Role-Based Transparency
# Dashboard). The four endpoints above stay as the shared summary.
# ---------------------------------------------------------------------------
from models.audit_log_model import AuditLog
from models.received_goods_model import ReceivedGoods
from models.inventory_model import Inventory
from models.item_model import Item
from models.delivery import DeliveryItem
from models.user_rbac_model import User
from models.report import DisasterType, Barangay
from models.donation_confirmation_model import DonationConfirmation
from core.auth import barangay_scope
from services.donation_entries import build_entries, group_by_report


def _labels(db: Session, report_ids) -> dict:
    if not report_ids:
        return {}
    types = {t.disaster_type_id: t.type_name for t in db.query(DisasterType).all()}
    brgys = {b.barangay_id: b.barangay_name for b in db.query(Barangay).all()}
    return {
        r.report_id: f"#{r.report_id} {types.get(r.disaster_type_id, 'Disaster')} - {brgys.get(r.barangay_id, 'Barangay')}"
        for r in db.query(DisasterReport).filter(DisasterReport.report_id.in_(report_ids)).all()
    }


def _recent_logs(db: Session, entity_types=None, limit=10) -> list:
    q = db.query(AuditLog, User.email).join(User, User.user_id == AuditLog.user_id)
    if entity_types:
        q = q.filter(AuditLog.entity_type.in_(entity_types))
    return [
        {"action": l.action, "entity_type": l.entity_type, "entity_id": l.entity_id,
         "by": email, "at": l.timestamp}
        for l, email in q.order_by(AuditLog.log_id.desc()).limit(limit).all()
    ]


@router.get("/csws-main")
def csws_main_dashboard(
    db: Session = Depends(get_db),
    user=Depends(require_role("csws_main_office", "admin")),
):
    """Manuscript 7.1 / UC-CM3."""
    donations = db.query(PhysicalDonation).order_by(PhysicalDonation.donation_id.desc()).all()
    items = {i.item_id: i for i in db.query(Item).all()}
    labels = _labels(db, {d.report_id for d in donations})
    received_qty = db.query(func.coalesce(func.sum(ReceivedGoods.actual_quantity), 0)).scalar() or 0
    distributed = (
        db.query(DeliveryItem.item_id, func.sum(DeliveryItem.quantity))
        .group_by(DeliveryItem.item_id).all()
    )
    inventory = (
        db.query(Inventory.item_id, func.sum(Inventory.quantity))
        .group_by(Inventory.item_id).all()
    )
    unit = lambda i: items[i].unit_of_measure if i in items else ""
    name = lambda i: items[i].item_name if i in items else f"Item #{i}"
    return {
        "pending_donations": sum(1 for d in donations if d.status == "Pending"),
        "entries_received": sum(1 for d in donations if d.status in ("Received", "Confirmed")),
        "total_quantity_received": int(received_qty),
        "deliveries_made": db.query(func.count(delivery.delivery_id)).scalar() or 0,
        "total_quantity_distributed": int(sum(q for _, q in distributed)),
        "inventory_summary": [
            {"item": name(i), "unit": unit(i), "quantity": int(q)} for i, q in inventory
        ],
        "distributed_summary": [
            {"item": name(i), "unit": unit(i), "quantity": int(q)} for i, q in distributed
        ],
        "donation_entries": [
            {
                "donation_id": d.donation_id,
                "qr_reference": d.qr_reference,
                "item_name": name(d.item_id),
                "unit": unit(d.item_id),
                "packaging": d.packaging,
                "declared_quantity": d.quantity,
                "estimated_value": float(d.estimated_value) if d.estimated_value is not None else None,
                "handover_method": d.handover_method,
                "report_label": labels.get(d.report_id),
                "status": d.status,
            }
            for d in donations[:20]
        ],
        "recent_activity": _recent_logs(
            db, ["physical_donations", "deliveries", "logistics_requests"]),
    }


@router.get("/barangay")
def barangay_dashboard(
    db: Session = Depends(get_db),
    user=Depends(require_role("barangay_receiving_rep")),
):
    """Manuscript 7.6 / UC-B2, limited to the assigned barangay."""
    own = barangay_scope(user)
    reports = db.query(DisasterReport).filter(DisasterReport.barangay_id == own).all()
    report_ids = [r.report_id for r in reports]
    labels = _labels(db, set(report_ids))
    donations = db.query(PhysicalDonation).filter(
        PhysicalDonation.report_id.in_(report_ids or [-1])).all()
    items = {i.item_id: i for i in db.query(Item).all()}
    deliveries = db.query(delivery).filter(delivery.destination_barangay_id == own).all()
    acked = {
        l.entity_id for l in db.query(AuditLog).filter(
            AuditLog.entity_type == "deliveries", AuditLog.action == "ACKNOWLEDGE AID").all()
    }
    return {
        "barangay": db.get(Barangay, own).barangay_name if db.get(Barangay, own) else None,
        "donations_linked": len(donations),
        "pending_city_confirmation": sum(1 for d in donations if d.status == "Received"),
        "confirmed": sum(1 for d in donations if d.status == "Confirmed"),
        "deliveries_received": sum(1 for d in deliveries if d.status == "Confirmed"),
        "acknowledged": sum(1 for d in deliveries if d.delivery_id in acked),
        "reports": [
            {
                "report_id": r.report_id,
                "report_label": labels.get(r.report_id),
                "status": r.status,
                "priority_level": r.priority_level,
                "confirmed_donations": sum(1 for d in donations
                                           if d.report_id == r.report_id and d.status == "Confirmed"),
                "total_items_needed": r.fulfillment.total_items_needed if r.fulfillment else r.estimated_quantity,
                "total_items_delivered": r.fulfillment.total_items_delivered if r.fulfillment else 0,
                "fulfillment_percentage": float(r.fulfillment.fulfillment_percentage) if r.fulfillment else 0.0,
            }
            for r in reports
        ],
        "donations": [
            {
                "qr_reference": d.qr_reference,
                "item_name": items[d.item_id].item_name if d.item_id in items else "Item",
                "quantity": d.quantity,
                "status": d.status,
                "report_label": labels.get(d.report_id),
            }
            for d in sorted(donations, key=lambda d: -d.donation_id)[:20]
        ],
        "acknowledged_deliveries": sorted(d.delivery_id for d in deliveries if d.delivery_id in acked),
    }


@router.get("/admin")
def admin_dashboard(
    db: Session = Depends(get_db),
    user=Depends(require_role("admin")),
):
    """Manuscript 7.7 / UC-A4 / wireframe Fig. 53."""
    held = len(_held_donation_ids(db))
    total_users = db.query(func.count(User.user_id)).scalar() or 0
    active_users = db.query(func.count(User.user_id)).filter(User.is_active.is_(True)).scalar() or 0
    return {
        "total_users": total_users,
        "active_users": active_users,
        "pending_organizations": db.query(func.count(Organization.organization_id))
            .filter(Organization.status == "Pending").scalar() or 0,
        "pending_validations": db.query(func.count(DisasterReport.report_id))
            .filter(DisasterReport.status == "Pending").scalar() or 0,
        "validated_reports": db.query(func.count(DisasterReport.report_id))
            .filter(DisasterReport.status == "Validated").scalar() or 0,
        "total_donations": db.query(func.count(PhysicalDonation.donation_id)).scalar() or 0,
        "held_donations": held,
        "recent_activity": _recent_logs(db, limit=15),
    }
def _held_donation_ids(db: Session) -> set:
    """Received donations whose latest CMO decision is On Hold."""
    latest = {}
    for c in db.query(DonationConfirmation).order_by(DonationConfirmation.confirmation_id).all():
        latest[c.donation_id] = c.status
    received = {
        d.donation_id
        for d in db.query(PhysicalDonation).filter(PhysicalDonation.status == "Received")
    }
    return {k for k, v in latest.items() if k in received and v == "On Hold"}


@router.get("/admin/reports")
def admin_dashboard_reports(
    status: str | None = None,
    db: Session = Depends(get_db),
    user=Depends(require_role("admin")),
):
    """5.1: the reports behind the admin dashboard's report tiles."""
    q = db.query(DisasterReport)
    if status:
        q = q.filter(DisasterReport.status == status)
    reports = q.order_by(DisasterReport.report_id.desc()).all()
    labels = _labels(db, {r.report_id for r in reports})
    return [
        {
            "report_id": r.report_id,
            "report_label": labels.get(r.report_id),
            "status": r.status,
            "priority_level": r.priority_level,
            "fulfillment_percentage": float(r.fulfillment.fulfillment_percentage)
            if r.fulfillment else 0.0,
        }
        for r in reports
    ]


@router.get("/admin/held")
def admin_held_donations(
    db: Session = Depends(get_db),
    user=Depends(require_role("admin")),
):
    """5.1 / 4.1: the held donations behind the dashboard tile, grouped
    Report -> Entries -> Items with the shared donation_entries helper."""
    held = _held_donation_ids(db)
    if not held:
        return {"held_donation_ids": [], "reports": []}
    report_ids = {
        rid for (rid,) in db.query(PhysicalDonation.report_id)
        .filter(PhysicalDonation.donation_id.in_(held)).distinct()
    }
    rows = db.query(PhysicalDonation).filter(PhysicalDonation.report_id.in_(report_ids)).all()
    # Group every donation of these reports first so "Donation 1, 2 ..."
    # numbers match the normal entries view, then keep only entries that
    # contain a held item.
    out = []
    for g in group_by_report(build_entries(db, rows, include_donor=True)):
        g["entries"] = [
            e for e in g["entries"] if any(i["donation_id"] in held for i in e["items"])
        ]
        if g["entries"]:
            g["total_entries"] = len(g["entries"])
            g["total_items"] = sum(e["total_items"] for e in g["entries"])
            out.append(g)
    return {"held_donation_ids": sorted(held), "reports": out}