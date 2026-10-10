"""Listing deliveries: filters, sorting and readable names (UC-CM2 step 6,
"monitor the movement of distributed goods"; Appendix H 8.5 delivery records).

Kept out of api/v1/deliveries.py so trips and the delivery list read the
same way.
"""
from datetime import date, datetime, time, timedelta
from typing import Optional

from sqlalchemy import case, func, or_
from sqlalchemy.orm import Session

from models.barangay_model import Barangay
from models.delivery import Delivery, DeliveryItem
from models.item_model import Item
from models.report import DisasterReport, DisasterType
from schemas.physical_donation_schema import MANILA

STATUS_ORDER = ["Preparing", "In Transit", "Delivered", "Confirmed", "Cancelled"]

# newest / oldest: when the delivery was prepared.
# date_soonest / date_latest: the planned delivery date.
# status: Preparing first, Confirmed last (what still needs work comes first).
DELIVERY_SORTS = ("newest", "oldest", "date_soonest", "date_latest", "status")


def _manila_start(d: date) -> datetime:
    return datetime.combine(d, time.min, tzinfo=MANILA)


def apply_delivery_filters(
    db: Session,
    query,
    status: Optional[str] = None,
    barangay_id: Optional[int] = None,
    report_id: Optional[int] = None,
    trip_id: Optional[int] = None,
    date_from: Optional[date] = None,
    date_to: Optional[date] = None,
    q: Optional[str] = None,
    sort: str = "newest",
):
    if status:
        wanted = [s.strip() for s in status.split(",") if s.strip()]
        query = query.filter(Delivery.status.in_(wanted))
    if barangay_id:
        query = query.filter(Delivery.destination_barangay_id == barangay_id)
    if report_id:
        query = query.filter(Delivery.report_id == report_id)
    if trip_id:
        query = query.filter(Delivery.trip_id == trip_id)
    if date_from:
        query = query.filter(Delivery.delivery_date >= _manila_start(date_from))
    if date_to:
        query = query.filter(Delivery.delivery_date < _manila_start(date_to + timedelta(days=1)))
    if q and q.strip():
        text = q.strip().lstrip("#")
        conds = []
        if text.isdigit():
            # A number is a delivery number (reports and trips have their own filters).
            conds.append(Delivery.delivery_id == int(text))
        like = f"%{text.lower()}%"
        brgy_ids = db.query(Barangay.barangay_id).filter(func.lower(Barangay.barangay_name).like(like))
        item_deliveries = (
            db.query(DeliveryItem.delivery_id)
            .join(Item, Item.item_id == DeliveryItem.item_id)
            .filter(func.lower(Item.item_name).like(like))
        )
        conds += [Delivery.destination_barangay_id.in_(brgy_ids),
                  Delivery.delivery_id.in_(item_deliveries)]
        query = query.filter(or_(*conds))

    if sort == "oldest":
        return query.order_by(Delivery.created_at.asc(), Delivery.delivery_id.asc())
    if sort == "date_soonest":
        return query.order_by(Delivery.delivery_date.asc(), Delivery.delivery_id.asc())
    if sort == "date_latest":
        return query.order_by(Delivery.delivery_date.desc(), Delivery.delivery_id.desc())
    if sort == "status":
        rank = case({s: i for i, s in enumerate(STATUS_ORDER)}, value=Delivery.status, else_=99)
        return query.order_by(rank, Delivery.delivery_date.asc(), Delivery.delivery_id.asc())
    return query.order_by(Delivery.created_at.desc(), Delivery.delivery_id.desc())


def status_counts(query) -> dict:
    counts = {s: 0 for s in STATUS_ORDER}
    for st, n in query.with_entities(Delivery.status, func.count(Delivery.delivery_id)).group_by(Delivery.status):
        counts[st] = n
    return {"total": sum(counts.values()), **counts}


def report_labels(db: Session, report_ids) -> dict:
    report_ids = set(report_ids)
    if not report_ids:
        return {}
    types = {t.disaster_type_id: t.type_name for t in db.query(DisasterType).all()}
    brgys = {b.barangay_id: b.barangay_name for b in db.query(Barangay).all()}
    return {
        r.report_id: f"#{r.report_id} {types.get(r.disaster_type_id, 'Disaster')} - {brgys.get(r.barangay_id, 'Barangay')}"
        for r in db.query(DisasterReport).filter(DisasterReport.report_id.in_(report_ids)).all()
    }


def delivery_views(db: Session, deliveries: list) -> list:
    """Deliveries as dicts with the names people read next to the ids."""
    if not deliveries:
        return []
    brgys = {
        b.barangay_id: b.barangay_name
        for b in db.query(Barangay).filter(
            Barangay.barangay_id.in_({d.destination_barangay_id for d in deliveries})).all()
    }
    item_ids = {i.item_id for d in deliveries for i in d.items}
    items = {i.item_id: i for i in db.query(Item).filter(Item.item_id.in_(item_ids)).all()} if item_ids else {}
    labels = report_labels(db, {d.report_id for d in deliveries})
    return [
        {
            "delivery_id": d.delivery_id,
            "report_id": d.report_id,
            "report_label": labels.get(d.report_id),
            "destination_barangay_id": d.destination_barangay_id,
            "destination_barangay_name": brgys.get(d.destination_barangay_id),
            "destination_sitio_id": d.destination_sitio_id,
            "handled_by_user_id": d.handled_by_user_id,
            "status": d.status,
            "delivery_date": d.delivery_date,
            "created_at": d.created_at,
            "trip_id": d.trip_id,
            "stop_order": d.stop_order,
            "cancelled_at": d.cancelled_at,
            "cancel_reason": d.cancel_reason,
            "items": [
                {
                    "delivery_item_id": i.delivery_item_id,
                    "item_id": i.item_id,
                    "quantity": i.quantity,
                    "item_name": items[i.item_id].item_name if i.item_id in items else None,
                    "unit": items[i.item_id].unit_of_measure if i.item_id in items else None,
                }
                for i in d.items
            ],
        }
        for d in deliveries
    ]