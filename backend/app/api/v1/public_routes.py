"""
Public, no-login summaries for the landing page (Item 8).
Only validated reports are exposed, and never who reported them
(no user_id, source, contact number or SMS text).
"""
from fastapi import APIRouter, Depends
from sqlalchemy import func
from sqlalchemy.orm import Session, joinedload, selectinload

from core.database import get_db
from models.report import DisasterReport, DisasterType, Barangay, Sitio
from models.delivery import Delivery, DeliveryItem, Receipt
from models.physical_donation_model import PhysicalDonation

router = APIRouter(prefix="/public", tags=["public"])

URGENT_LEVELS = ("Critical", "High")   # assumption: confirm with the team
RECEIVED_STATUSES = ("Received", "Confirmed")   # past CSWS receipt; Confirmed follows Received
DELIVERED_STATUS = "Delivered"         # from the 3.10 status flow


@router.get("/reports")
def public_reports(db: Session = Depends(get_db)):
    types = {t.disaster_type_id: t.type_name for t in db.query(DisasterType).all()}
    barangays = {b.barangay_id: b.barangay_name for b in db.query(Barangay).all()}
    sitios = {s.sitio_id: s.sitio_name for s in db.query(Sitio).all()}

    rows = (
        db.query(DisasterReport)
        .options(joinedload(DisasterReport.fulfillment))
        .filter(DisasterReport.status == "Validated")
        .order_by(DisasterReport.report_id.desc())
        .limit(200)
        .all()
    )

    out = []
    for r in rows:
        f = r.fulfillment
        out.append({
            "id": r.report_id,
            "report_id": r.report_id,
            "disaster": types.get(r.disaster_type_id, "Disaster"),
            "barangay": barangays.get(r.barangay_id, "Barangay"),
            "sitio": sitios.get(r.sitio_id),
            "priority_level": r.priority_level,
            "assistance_needed": r.assistance_needed,
            "affected_families": r.affected_families,
            "description": r.description,
            "total_items_needed": f.total_items_needed if f else (r.estimated_quantity or 0),
            "total_items_delivered": f.total_items_delivered if f else 0,
            "fulfillment_percentage": float(f.fulfillment_percentage) if f else 0.0,
        })
    return out


@router.get("/stats")
def public_stats(db: Session = Depends(get_db)):
    validated = DisasterReport.status == "Validated"

    active = db.query(func.count(DisasterReport.report_id)).filter(validated).scalar() or 0
    families = (db.query(func.coalesce(func.sum(DisasterReport.affected_families), 0))
                .filter(validated).scalar() or 0)
    urgent = (db.query(func.count(DisasterReport.report_id))
              .filter(validated, DisasterReport.priority_level.in_(URGENT_LEVELS))
              .scalar() or 0)
    brgys = (db.query(func.count(func.distinct(DisasterReport.barangay_id)))
             .filter(validated).scalar() or 0)
    donations = (db.query(func.count(PhysicalDonation.donation_id))
                 .filter(PhysicalDonation.status.in_(RECEIVED_STATUSES)).scalar() or 0)
    delivered = (db.query(func.count(Delivery.delivery_id))
                 .filter(Delivery.status == DELIVERED_STATUS).scalar() or 0)

    return {
        "active_reports": active,
        "families_affected": int(families),
        "urgent_reports": urgent,
        "barangays": brgys,
        "donations_received": donations,
        "deliveries_completed": delivered,
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
