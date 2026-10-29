"""
Read-only reference data for dropdowns (disaster types, barangays, sitios,
items, reports), so users pick names instead of typing ids.

Public: anyone may call it, guest donors too. Without a login it returns the
reference lists and the validated reports, which hold no personal data (no
donor names or contacts).

F-01: the six lists of internal records (every report, pending and received
donations, open and delivered deliveries, pending DRRMO requests) are filled
only for the staff role whose screen uses them (INTERNAL_LIST_ROLES). Every
other caller gets them as empty lists, so the response keeps the same keys.
"""
from typing import Optional

from fastapi import APIRouter, Depends
from sqlalchemy.orm import Session, joinedload

from core.auth import get_current_user_optional, has_role
from core.database import get_db
from models.report import DisasterReport, DisasterType, Barangay, Sitio
from models.disaster_type_model import OTHER_DISASTER_TYPE
from models.item_model import Item
from models.physical_donation_model import PhysicalDonation
from models.delivery import Delivery
from models.logistics_request_model import LogisticsRequest
from models.user_rbac_model import User
from services.fulfillment import progress_for_reports
from services.need_templates import need_templates
from services.units import dimension, units_for

router = APIRouter(prefix="/lookups", tags=["lookups"])

LIMIT = 200  # newest rows per list, as before

# F-01: who receives each internal list. Each list fills one dropdown
# (mobile/lib/modules.dart), so it goes only to the role(s) using it:
#   reports              Administrator: validate / reject a report
#                        (POST /reports/{id}/validate, /reject)
#                        CSWS Main Office: report filter of the inventory
#                        (GET /donations/inventory)
#   pending_donations    CSWS Main Office: receive goods (POST /donations/receive)
#   received_donations   CMO Representative: acknowledge a donation
#                        (POST /cmo/donations/{id}/confirm)
#   open_deliveries      CSWS Main Office: advance a delivery
#                        (POST /deliveries/{id}/advance) and ask DRRMO for
#                        transport (POST /logistics/requests)
#   delivered_deliveries Barangay Receiving Representative, own barangay only:
#                        confirm receipt (POST /deliveries/{id}/confirm-receipt)
#   pending_requests     DRRMO Logistics Support: accept / decline
#                        (PATCH /drrmo/requests/{id}/accept, /decline)
INTERNAL_LIST_ROLES = {
    "reports": ("Administrator", "CSWS Main Office"),
    "pending_donations": ("CSWS Main Office",),
    "received_donations": ("CMO Representative",),
    "open_deliveries": ("CSWS Main Office",),
    "delivered_deliveries": ("Barangay Receiving Representative",),
    "pending_requests": ("DRRMO Logistics Support",),
}


def _may_see(user: Optional[User], key: str) -> bool:
    # The role is the account's role in the database (core/auth.py), never
    # anything the request says about itself.
    return user is not None and has_role(user, *INTERNAL_LIST_ROLES[key])


@router.get("")
def get_lookups(
    db: Session = Depends(get_db),
    # Login is optional: no token, or an invalid or expired one, is a guest.
    # A deactivated account's token gets 403, as on every other endpoint.
    user: Optional[User] = Depends(get_current_user_optional),
):
    types = {t.disaster_type_id: t.type_name for t in db.query(DisasterType).all()}
    barangays = {b.barangay_id: b.barangay_name for b in db.query(Barangay).all()}
    sitios = db.query(Sitio).order_by(Sitio.barangay_id, Sitio.sitio_id).all()

    def label(r):
        return (f"#{r.report_id} {r.disaster_label(types)} - "
                f"{barangays.get(r.barangay_id, 'Barangay')}")

    # Public: the validated reports, from their own query, so newer Pending,
    # Rejected or Cancelled reports can never push them out of the limit.
    # Deleted reports (testing 2.3, soft delete) stay out of every list.
    validated = (db.query(DisasterReport).options(joinedload(DisasterReport.fulfillment))
                 .filter(DisasterReport.status == "Validated",
                         DisasterReport.deleted_at.is_(None))
                 .order_by(DisasterReport.report_id.desc()).limit(LIMIT).all())
    progress = progress_for_reports(db, validated)

    out = {
        # In id order, with Other always last.
        "disaster_types": [{"id": i, "name": n} for i, n in sorted(
            types.items(), key=lambda t: (t[1] == OTHER_DISASTER_TYPE, t[0]))],
        "barangays": [{"id": i, "name": n} for i, n in sorted(barangays.items(), key=lambda x: x[1])],
        "sitios": [
            {"id": s.sitio_id, "name": s.sitio_name, "barangay_id": s.barangay_id}
            for s in sitios
        ],
                # Retired items (active = false) and items waiting for review (F-15) stay out of the dropdowns.

        "items": [
            {"id": i.item_id, "name": f"{i.item_name} ({i.unit_of_measure})",
             "item_name": i.item_name, "unit": i.unit_of_measure,
             "kind": dimension(i.unit_of_measure),
             "size_units": units_for(i.unit_of_measure),
             "sizes": [{"id": z.size_id, "label": z.label, "amount": float(z.amount)}
                       for z in i.sizes]}
            for i in db.query(Item).filter(Item.active.is_(True), Item.pending_review.is_(False)).order_by(Item.item_name).all()

        ],
        # Staff only (F-01): every report, with its status. Filled below.
        "reports": [],
        # Donor / organization screens: only validated reports are published
        # to donors (manuscript UC-A3 step 9, UC-D2).
        "validated_reports": [
            {
                "id": r.report_id,
                "name": f"{label(r)} - {r.priority_level or 'No priority'}",
                # Public summary for donor cards (UC-D2 step 2: needs,
                # priority guidance and fulfillment status).
                "disaster": r.disaster_label(types),
                "barangay": barangays.get(r.barangay_id, "Barangay"),
                "barangay_id": r.barangay_id,
                "sitio": ", ".join(r.sitio_names) or None,
                "sitios": r.sitio_names,
                "priority_level": r.priority_level,
                "assistance_needed": r.assistance_needed,
                "affected_families": r.affected_families,
                "description": r.description,
                "total_items_needed": r.fulfillment.total_items_needed if r.fulfillment else r.estimated_quantity,
                "total_items_delivered": r.fulfillment.total_items_delivered if r.fulfillment else 0,
                "fulfillment_percentage": float(r.fulfillment.fulfillment_percentage) if r.fulfillment else 0.0,
                # Per need: needed / pledged / confirmed / delivered, so the
                # donate screen can say what is still missing.
                "needs": progress[r.report_id]["needs"],
                # Ivan (donor feed): "New validated report · 2h".
                "created_at": r.created_at.isoformat() if r.created_at else None,
            }
            for r in validated
        ],
        # Staff only (F-01). Filled below for the roles in INTERNAL_LIST_ROLES.
        "pending_donations": [],     # CSWS receives these
        "received_donations": [],    # CMO confirms these
        "open_deliveries": [],       # CSWS advances
        "delivered_deliveries": [],  # Barangay acknowledges
        "pending_requests": [],      # DRRMO accepts / declines
    }

    # Each internal query runs only for a caller allowed to see its result.
    if _may_see(user, "reports"):
        rows = (db.query(DisasterReport).filter(DisasterReport.deleted_at.is_(None))
                .order_by(DisasterReport.report_id.desc()).limit(LIMIT).all())
        out["reports"] = [
            {"id": r.report_id, "name": f"{label(r)} ({r.status})", "status": r.status}
            for r in rows
        ]

    if _may_see(user, "pending_donations") or _may_see(user, "received_donations"):
        item_names = {i.item_id: i.item_name for i in db.query(Item).all()}

        def donations(status):
            rows = (db.query(PhysicalDonation).filter(PhysicalDonation.status == status)
                    .order_by(PhysicalDonation.donation_id.desc()).limit(LIMIT).all())
            return [{"id": d.donation_id,
                     "name": f"#{d.donation_id} {d.qr_reference} - {d.quantity} "
                             f"{item_names.get(d.item_id, 'item')} for report #{d.report_id}"}
                    for d in rows]

        if _may_see(user, "pending_donations"):
            out["pending_donations"] = donations("Pending")
        if _may_see(user, "received_donations"):
            out["received_donations"] = donations("Received")

    def deliveries(*statuses, barangay_id=None):
        query = db.query(Delivery).filter(Delivery.status.in_(statuses))
        if barangay_id is not None:
            query = query.filter(Delivery.destination_barangay_id == barangay_id)
        rows = query.order_by(Delivery.delivery_id.desc()).limit(LIMIT).all()
        return [{"id": d.delivery_id,
                 "name": f"#{d.delivery_id} to {barangays.get(d.destination_barangay_id, 'Barangay')}"
                         f" - report #{d.report_id} ({d.status})"}
                for d in rows]

    if _may_see(user, "open_deliveries"):
        out["open_deliveries"] = deliveries("Preparing", "In Transit")
    if _may_see(user, "delivered_deliveries"):
        # Only the representative's own barangay (UC-B1 alt 3a, the rule of
        # core.auth.barangay_scope). Without an assigned barangay the list
        # stays empty instead of failing, so the reference lists still load.
        own = getattr(user, "assigned_barangay_id", None)
        if own is not None:
            out["delivered_deliveries"] = deliveries("Delivered", barangay_id=own)

    if _may_see(user, "pending_requests"):
        requests = (db.query(LogisticsRequest).filter(LogisticsRequest.status == "Pending")
                    .order_by(LogisticsRequest.request_id.desc()).limit(LIMIT).all())
        out["pending_requests"] = [
            {"id": r.request_id, "name": f"#{r.request_id} for {r.title}"}
            for r in requests
        ]

    # Module 3 (Oct 2026): suggested needs per disaster type, per family.
    # Public like the other reference lists: item names and amounts only.
    out["need_templates"] = need_templates(db)

    return out

