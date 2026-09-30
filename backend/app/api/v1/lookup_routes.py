"""
Read-only reference data for dropdowns (disaster types, barangays, sitios,
items, reports), so users pick names instead of typing ids.
Public: it holds no personal data (no donor names or contacts), and guest
donors need it too.
"""
from fastapi import APIRouter, Depends
from sqlalchemy.orm import Session, joinedload

from core.database import get_db
from models.report import DisasterReport, DisasterType, Barangay, Sitio
from models.item_model import Item
from models.physical_donation_model import PhysicalDonation
from models.delivery import Delivery
from models.logistics_request_model import LogisticsRequest

router = APIRouter(prefix="/lookups", tags=["lookups"])


@router.get("")
def get_lookups(db: Session = Depends(get_db)):
    types = {t.disaster_type_id: t.type_name for t in db.query(DisasterType).all()}
    barangays = {b.barangay_id: b.barangay_name for b in db.query(Barangay).all()}
    sitios = db.query(Sitio).order_by(Sitio.barangay_id, Sitio.sitio_id).all()
    sitio_names = {s.sitio_id: s.sitio_name for s in sitios}

    reports = (db.query(DisasterReport).options(joinedload(DisasterReport.fulfillment))
               .order_by(DisasterReport.report_id.desc()).limit(200).all())

    def label(r):
        return (f"#{r.report_id} {types.get(r.disaster_type_id, 'Disaster')} - "
                f"{barangays.get(r.barangay_id, 'Barangay')}")

    items = {i.item_id: i.item_name for i in db.query(Item).all()}

    def donations(status):
        rows = (db.query(PhysicalDonation).filter(PhysicalDonation.status == status)
                .order_by(PhysicalDonation.donation_id.desc()).limit(200).all())
        return [{"id": d.donation_id,
                 "name": f"#{d.donation_id} {d.qr_reference} - {d.quantity} "
                         f"{items.get(d.item_id, 'item')} for report #{d.report_id}"}
                for d in rows]

    def deliveries(*statuses):
        rows = (db.query(Delivery).filter(Delivery.status.in_(statuses))
                .order_by(Delivery.delivery_id.desc()).limit(200).all())
        return [{"id": d.delivery_id,
                 "name": f"#{d.delivery_id} to {barangays.get(d.destination_barangay_id, 'Barangay')}"
                         f" - report #{d.report_id} ({d.status})"}
                for d in rows]

    requests = (db.query(LogisticsRequest).filter(LogisticsRequest.status == "Pending")
                .order_by(LogisticsRequest.request_id.desc()).limit(200).all())

    return {
        "disaster_types": [{"id": i, "name": n} for i, n in sorted(types.items())],
        "barangays": [{"id": i, "name": n} for i, n in sorted(barangays.items(), key=lambda x: x[1])],
        "sitios": [
            {"id": s.sitio_id, "name": s.sitio_name, "barangay_id": s.barangay_id}
            for s in sitios
        ],
        "items": [
            {"id": i.item_id, "name": f"{i.item_name} ({i.unit_of_measure})",
             "item_name": i.item_name, "unit": i.unit_of_measure}
            for i in db.query(Item).order_by(Item.item_name).all()
        ],
        # Staff screens: every report, with its status.
        "reports": [
            {"id": r.report_id, "name": f"{label(r)} ({r.status})", "status": r.status}
            for r in reports
        ],
        # Donor / organization screens: only validated reports are published
        # to donors (manuscript UC-A3 step 9, UC-D2).
        "validated_reports": [
            {
                "id": r.report_id,
                "name": f"{label(r)} - {r.priority_level or 'No priority'}",
                # Public summary for donor cards (UC-D2 step 2: needs,
                # priority guidance and fulfillment status).
                "disaster": types.get(r.disaster_type_id, "Disaster"),
                "barangay": barangays.get(r.barangay_id, "Barangay"),
                "barangay_id": r.barangay_id,
                "sitio": sitio_names.get(r.sitio_id),
                "priority_level": r.priority_level,
                "assistance_needed": r.assistance_needed,
                "affected_families": r.affected_families,
                "description": r.description,
                "total_items_needed": r.fulfillment.total_items_needed if r.fulfillment else r.estimated_quantity,
                "total_items_delivered": r.fulfillment.total_items_delivered if r.fulfillment else 0,
                "fulfillment_percentage": float(r.fulfillment.fulfillment_percentage) if r.fulfillment else 0.0,
            }
            for r in reports if r.status == "Validated"
        ],
        "pending_donations": donations("Pending"),     # CSWS receives these
        "received_donations": donations("Received"),   # CMO confirms these
        "open_deliveries": deliveries("Preparing", "In Transit"),  # CSWS advances
        "delivered_deliveries": deliveries("Delivered"),  # Barangay acknowledges
        "pending_requests": [                          # DRRMO accepts / declines
            {"id": r.request_id, "name": f"#{r.request_id} for delivery #{r.delivery_id}"}
            for r in requests
        ],
    }
