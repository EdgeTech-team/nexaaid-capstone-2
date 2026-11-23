"""
Public, no-login summaries for the landing page (Item 8).
Only validated reports are exposed, and never who reported them
(no user_id, source, contact number or SMS text).
"""
from services.deliveries.fulfillment import progress_for_reports
from typing import Optional

from fastapi import APIRouter, Depends, Query, Response
from sqlalchemy import func, select
from sqlalchemy.orm import Session, joinedload, selectinload

from core.security.auth import get_current_user_optional
from core.config.database import get_db
from core.common.pagination import PageParams, paginate_list, set_total_header
from services.reports import report_feed
from models.reports.report import DisasterReport, DisasterType, Barangay
from models.deliveries.delivery import Delivery, DeliveryItem, Receipt
from models.donations.physical_donation_model import PhysicalDonation
from core.priority_ai.priority_engine import explain_priority

router = APIRouter(prefix="/public", tags=["public"])

URGENT_LEVELS = ("Critical", "High")   # assumption: confirm with the team
RECEIVED_STATUSES = ("Received", "Confirmed")   # past CSWS receipt; Confirmed follows Received
DELIVERED_STATUS = "Delivered"         # from the 3.10 status flow


def _feed_reports(db: Session):
    """Every validated report, newest first, with what the feed filters on."""
    return (
        db.query(DisasterReport)
        .options(joinedload(DisasterReport.fulfillment), joinedload(DisasterReport.event))
        .filter(DisasterReport.status == "Validated", DisasterReport.deleted_at.is_(None))
        .order_by(DisasterReport.report_id.desc())
        .all()
    )


def _names(db: Session):
    types = {t.disaster_type_id: t.type_name for t in db.query(DisasterType).all()}
    barangays = {b.barangay_id: b.barangay_name for b in db.query(Barangay).all()}
    return types, barangays


@router.get("/reports/feed")
def report_feed_page(
    response: Response,
    done: Optional[bool] = Query(default=None, description="true = fulfilled only, false = still needs help"),
    q: Optional[str] = Query(default=None, max_length=100),
    barangay: Optional[str] = Query(default=None, max_length=100),
    disaster: Optional[str] = Query(default=None, max_length=100),
    priority: Optional[str] = Query(default=None, max_length=50),
    quick: str = Query(default="all"),
    sort: str = Query(default="urgent"),
    page: PageParams = Depends(),
    db: Session = Depends(get_db),
    user=Depends(get_current_user_optional),
):
    """NF-003 (Donor, Organization, guest): the validated reports feed,
    filtered, sorted and 20 at a time on the server. Rows are the same as
    GET /lookups `validated_reports`; guests never see sitio names in the
    search (4.2)."""
    types, barangays = _names(db)
    rows = report_feed.select(_feed_reports(db), types, barangays, done=done, q=q,
                              barangay=barangay, disaster=disaster, priority=priority,
                              quick=quick, sort=sort, with_sitio=user is not None)
    rows, total = paginate_list(rows, page)
    set_total_header(response, page, total)
    progress = progress_for_reports(db, rows)

    def label(r):
        return f"#{r.report_id} {r.disaster_label(types)} - {barangays.get(r.barangay_id, 'Barangay')}"

    return [report_feed.feed_row(r, types, barangays, progress, label) for r in rows]


@router.get("/reports/feed/counts")
def report_feed_counts(
    done: Optional[bool] = Query(default=None),
    db: Session = Depends(get_db),
):
    """The two summary cards: all reports in the feed and how many are High
    or Critical priority."""
    types, barangays = _names(db)
    rows = report_feed.select(_feed_reports(db), types, barangays, done=done)
    return {"all": len(rows), "urgent": sum(1 for r in rows if r.priority_level in report_feed.URGENT)}


@router.get("/reports")
def public_reports(db: Session = Depends(get_db)):
    types = {t.disaster_type_id: t.type_name for t in db.query(DisasterType).all()}
    barangays = {b.barangay_id: b.barangay_name for b in db.query(Barangay).all()}

    rows = (
        db.query(DisasterReport)
        .options(
            joinedload(DisasterReport.fulfillment),
            joinedload(DisasterReport.disaster_type),
            joinedload(DisasterReport.event),
        )
        .filter(DisasterReport.status == "Validated")
        .order_by(DisasterReport.report_id.desc())
        .limit(200)
        .all()
    )

    # Per-item progress for every report in a few queries (Oct 2026).
    progress = progress_for_reports(db, rows)
    out = []
    for r in rows:
        f = r.fulfillment
        out.append({
            "id": r.report_id,
            "report_id": r.report_id,
            "disaster": r.disaster_label(types),
            "barangay": barangays.get(r.barangay_id, "Barangay"),
            # NF-003: the multi-barangay event, so a guest can switch to
            # another barangay of the same disaster on the donate form.
            "event_id": r.event_id,
            "event_name": r.event_name,
            "sitio": ", ".join(r.sitio_names) or None,
            "sitios": r.sitio_names,
            "priority_level": r.priority_level,
            # How the report came in (Web / Mobile / SMS). Never who
            # reported it. The app no longer shows it (problema_napud 2.1:
            # no "via Mobile / via SMS"); kept so older clients still work.
            "source": r.source,
            "priority_guidance": explain_priority(r),
            "assistance_needed": r.assistance_needed,
            "affected_families": r.affected_families,
            "description": r.description,
            "total_items_needed": f.total_items_needed if f else (r.estimated_quantity or 0),
            "total_items_delivered": f.total_items_delivered if f else 0,
            "fulfillment_percentage": float(f.fulfillment_percentage) if f else 0.0,
            # One line per need: needed / pledged / confirmed / delivered.
            "needs": progress[r.report_id]["needs"],
        })
    return out



@router.get("/stats")
def public_stats(db: Session = Depends(get_db)):
    validated = DisasterReport.status == "Validated"

    stats_query = select(
        db.query(func.count(DisasterReport.report_id))
        .filter(validated)
        .scalar_subquery()
        .label("active_reports"),

        db.query(
            func.coalesce(
                func.sum(DisasterReport.affected_families), 0
            )
        )
        .filter(validated)
        .scalar_subquery()
        .label("families_affected"),

        db.query(func.count(DisasterReport.report_id))
        .filter(
            validated,
            DisasterReport.priority_level.in_(URGENT_LEVELS),
        )
        .scalar_subquery()
        .label("urgent_reports"),

        db.query(func.count(func.distinct(DisasterReport.barangay_id)))
        .filter(validated)
        .scalar_subquery()
        .label("barangays"),

        db.query(func.count(PhysicalDonation.donation_id))
        .filter(PhysicalDonation.status.in_(RECEIVED_STATUSES))
        .scalar_subquery()
        .label("donations_received"),

        db.query(func.count(Delivery.delivery_id))
        .filter(Delivery.status == DELIVERED_STATUS)
        .scalar_subquery()
        .label("deliveries_completed"),
    )

    row = db.execute(stats_query).one()

    return {
        "active_reports": row.active_reports or 0,
        "families_affected": int(row.families_affected or 0),
        "urgent_reports": row.urgent_reports or 0,
        "barangays": row.barangays or 0,
        "donations_received": row.donations_received or 0,
        "deliveries_completed": row.deliveries_completed or 0,
    }

@router.get("/recent-deliveries")
def public_recent_deliveries(db: Session = Depends(get_db)):
    """Latest deliveries the barangay has confirmed, newest first (max 5).
    Only the goods, the barangay and the confirmation time: no donor,
    handler, receiver or remarks."""
    rows = (
        db.query(Delivery)
        .join(Receipt, Receipt.delivery_id == Delivery.delivery_id)
        .options(
            selectinload(Delivery.items).selectinload(DeliveryItem.item),
            joinedload(Delivery.destination_barangay),
            joinedload(Delivery.receipt),
        )
        .filter(Delivery.status == "Confirmed")
        .order_by(Receipt.received_at.desc())
        .limit(5)
        .all()
    )

    out = []
    for d in rows:
        names = [i.item.item_name for i in d.items if i.item is not None]
        if not names:
            summary = "Relief goods"
        elif len(names) == 1:
            summary = names[0]
        else:
            summary = f"{names[0]} and {len(names) - 1} more"
        out.append({
            "summary": summary,
            "barangay": d.destination_barangay.barangay_name if d.destination_barangay else None,
            "confirmed_at": d.receipt.received_at.isoformat() if d.receipt else None,
        })
    return out
