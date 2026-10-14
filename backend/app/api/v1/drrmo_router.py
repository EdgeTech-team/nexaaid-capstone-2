# Manuscript UC-DR1 / UC-DR2 and the Logistics Support Coordination Module.
from datetime import datetime, timezone
from typing import Optional

from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel, Field
from sqlalchemy.orm import Session

from core.database import get_db
from core.auth import require_role
from core.audit import log_action
from models.user_rbac_model import User
from models.logistics_request_model import LogisticsRequest
from models.delivery import Delivery
from models.item_model import Item
from models.report import DisasterReport, DisasterType, Barangay
from models.physical_donation_model import PhysicalDonation
from services.donation_expiry import entry_status
from core.notifications import notify_event
from schemas.logistics_request_schema import (
    AcceptLogisticsRequest, DeclineLogisticsRequest, LogisticsRequestResponse
)

router = APIRouter(prefix="/drrmo", tags=["drrmo"])

DRRMO = "DRRMO Logistics Support"

# 3.11 levels, most urgent first. Reports the engine couldn't score
# ("Needs Review" is stored as NULL) go last.
PRIORITY_RANK = {"Critical": 0, "High": 1, "Medium": 2, "Low": 3}


def priority_sort_key(row: dict):
    """Most urgent report first. Within the same level, the oldest request first."""
    return (PRIORITY_RANK.get(row.get("priority_level"), len(PRIORITY_RANK)), row["request_id"])


def _pickup_stops(db: Session, requests) -> dict:
    """request_id -> the Door to Door stops of a pickup run, in stop order.
    DRRMO gets where to go and what to load, not the donor's name or number
    (CSWS Disaster Unit coordinates with the donors)."""
    refs = {ref for r in requests if r.request_type == "Pickup" for ref in r.batch_list}
    if not refs:
        return {}
    rows = (db.query(PhysicalDonation)
            .filter(PhysicalDonation.batch_reference.in_(refs))
            .order_by(PhysicalDonation.donation_id).all())
    items = {i.item_id: i for i in db.query(Item).filter(
        Item.item_id.in_({r.item_id for r in rows} or {-1})).all()}
    by_ref: dict = {}
    for row in rows:
        by_ref.setdefault(row.batch_reference, []).append(row)
    out = {}
    for r in requests:
        if r.request_type != "Pickup":
            continue
        stops = []
        for n, ref in enumerate(r.batch_list, start=1):
            lines = by_ref.get(ref, [])
            first = lines[0] if lines else None
            stops.append({
                "stop": n,
                "batch_reference": ref,
                "landmark": first.pickup_landmark if first else None,
                "address": first.pickup_address if first else None,
                "lat": float(first.pickup_lat) if first and first.pickup_lat is not None else None,
                "lng": float(first.pickup_lng) if first and first.pickup_lng is not None else None,
                "report_id": first.report_id if first else None,
                "status": entry_status({l.status for l in lines}) if lines else "Unknown",
                "goods": [
                    f"{l.quantity} {items[l.item_id].unit_of_measure} {items[l.item_id].item_name}"
                    if l.item_id in items else f"{l.quantity} item(s)"
                    for l in lines
                ],
            })
        out[r.request_id] = stops
    return out


def request_rows(db: Session, requests) -> list:
    """Requests with their delivery (or pickup run) details, used by DRRMO,
    CSWS Main Office and Disaster Unit screens."""
    deliveries = {
        d.delivery_id: d
        for d in db.query(Delivery).filter(
            Delivery.delivery_id.in_([r.delivery_id for r in requests if r.delivery_id] or [-1])
        ).all()
    }
    pickup_stops = _pickup_stops(db, requests)
    items = {i.item_id: i for i in db.query(Item).all()}
    types = {t.disaster_type_id: t.type_name for t in db.query(DisasterType).all()}
    brgys = {b.barangay_id: b.barangay_name for b in db.query(Barangay).all()}
    report_ids = {d.report_id for d in deliveries.values()}
    report_ids |= {s["report_id"] for stops in pickup_stops.values() for s in stops if s["report_id"]}
    reports = {r.report_id: r for r in db.query(DisasterReport).filter(
        DisasterReport.report_id.in_(report_ids or [-1])).all()}
    requesters = {u.user_id: u for u in db.query(User).filter(
        User.user_id.in_({r.requested_by_user_id for r in requests} or {-1})).all()}
    out = []
    for r in requests:
        d = deliveries.get(r.delivery_id) if r.delivery_id else None
        stops = pickup_stops.get(r.request_id, [])
        if r.request_type == "Pickup":
            # The most urgent report among the stops decides the priority.
            linked = [reports[s["report_id"]] for s in stops if s["report_id"] in reports]
            rep = min(linked, key=lambda x: PRIORITY_RANK.get(x.priority_level, len(PRIORITY_RANK)),
                      default=None)
        else:
            rep = reports.get(d.report_id) if d else None
        stage = r.status
        if r.status == "Accepted" and d is not None and d.status in ("In Transit", "Delivered"):
            stage = "In Transit"  # UC-DR2: in-transit support, from the delivery's tracking status
        who = requesters.get(r.requested_by_user_id)
        landmarks = []
        for s in stops:
            if s["landmark"] and s["landmark"] not in landmarks:
                landmarks.append(s["landmark"])
        out.append({
            "request_id": r.request_id,
            "request_type": r.request_type or "Delivery",
            "delivery_id": r.delivery_id,
            "status": r.status,
            "stage": stage,
            "scheduled_date": r.scheduled_date,
            "notes": r.notes,
            # 7.2: what is needed, on its own line for the request card.
            "needs": next((line for line in (r.notes or "").splitlines()
                           if line.startswith("Needs ")), None),
            "created_at": r.created_at,
            "requested_by": f"{who.first_name} {who.last_name}".strip() if who else None,
            "requested_by_role": who.role.role_name if who and who.role else None,
            "pickup_date": r.pickup_date.isoformat() if r.pickup_date else None,
            "stops": stops,
            "delivery_status": d.status if d else None,
            "destination": (
                (brgys.get(d.destination_barangay_id) if d else None) if r.request_type != "Pickup"
                else f"{len(stops)} Door to Door stop{'s' if len(stops) != 1 else ''}"
                     + (f" near {', '.join(landmarks[:3])}" if landmarks else "")
            ),
            "report_label": (
                r.title[0].upper() + r.title[1:] if r.request_type == "Pickup"
                else (f"#{rep.report_id} {types.get(rep.disaster_type_id, 'Disaster')} - "
                      f"{brgys.get(rep.barangay_id, 'Barangay')}") if rep else None
            ),
            "report_id": rep.report_id if rep else None,
            "priority_level": rep.priority_level if rep else None,
            "ai_priority_score": (float(rep.ai_priority_score)
                                  if rep and rep.ai_priority_score is not None else None),
            "goods": (
                [g for s in stops for g in s["goods"]] if r.request_type == "Pickup" else [
                    f"{i.quantity} {items[i.item_id].unit_of_measure} {items[i.item_id].item_name}"
                    if i.item_id in items else f"{i.quantity} item(s)"
                    for i in (d.items if d else [])
                ]
            ),
        })
    return out


@router.get("/requests")
def list_requests(
    status: Optional[str] = Query(default=None, description="Pending / Accepted / Declined / Completed"),
    priority_level: Optional[str] = Query(default=None, description="Critical / High / Medium / Low"),
    db: Session = Depends(get_db),
    current_user: User = Depends(require_role(DRRMO)),
):
    """UC-DR1 step 1: DRRMO sees requests ordered by the linked report's
    3.11 priority, so the most urgent deliveries get scheduled first."""
    query = db.query(LogisticsRequest)
    if status:
        query = query.filter(LogisticsRequest.status == status)
    rows = request_rows(db, query.all())
    if priority_level:
        rows = [r for r in rows if r["priority_level"] == priority_level]
    return sorted(rows, key=priority_sort_key)


@router.patch("/requests/{request_id}/accept", response_model=LogisticsRequestResponse)
def accept_request(
    request_id: int,
    payload: AcceptLogisticsRequest,
    db: Session = Depends(get_db),
    current_user: User = Depends(require_role(DRRMO)),
):
    req = db.query(LogisticsRequest).filter(LogisticsRequest.request_id == request_id).first()
    if req is None:
        raise HTTPException(status_code=404, detail="Logistics request not found")
    if req.status != "Pending":
        raise HTTPException(status_code=400, detail=f"Request is already {req.status}, cannot accept")

    req.status = "Accepted"
    req.assigned_to_user_id = current_user.user_id
    if payload.notes:  # keep what CSWS asked for
        req.notes = f"{req.notes}\nDRRMO: {payload.notes}" if req.notes else f"DRRMO: {payload.notes}"
    log_action(db, current_user, "ACCEPT LOGISTICS REQUEST", "logistics_requests", request_id,
               old={"status": "Pending"}, new={"status": "Accepted"})
    notify_event(db, req.requested_by_user_id, "logistics_accepted",
                 "logistics_request", request_id,
                 title=req.title)

    db.commit()
    db.refresh(req)
    return req


@router.patch("/requests/{request_id}/decline", response_model=LogisticsRequestResponse)
def decline_request(
    request_id: int,
    payload: DeclineLogisticsRequest,
    db: Session = Depends(get_db),
    current_user: User = Depends(require_role(DRRMO)),
):
    req = db.query(LogisticsRequest).filter(LogisticsRequest.request_id == request_id).first()
    if req is None:
        raise HTTPException(status_code=404, detail="Logistics request not found")
    if req.status != "Pending":
        raise HTTPException(status_code=400, detail=f"Request is already {req.status}, cannot decline")

    req.status = "Declined"
    req.assigned_to_user_id = current_user.user_id
    req.notes = payload.notes
    log_action(db, current_user, "DECLINE LOGISTICS REQUEST", "logistics_requests", request_id,
               old={"status": "Pending"}, new={"status": "Declined", "reason": payload.notes})
    notify_event(db, req.requested_by_user_id, "logistics_declined",
                 "logistics_request", request_id, reason=payload.notes or "")

    db.commit()
    db.refresh(req)
    return req


class CompleteLogisticsRequest(BaseModel):
    """Logistics assistance summary (module step: date completed, goods
    transported, destination). Alt 6a: required before saving as completed."""
    summary: str = Field(..., min_length=3, max_length=1000)
    completed_at: Optional[datetime] = None


@router.patch("/requests/{request_id}/complete")
def complete_request(
    request_id: int,
    payload: CompleteLogisticsRequest,
    db: Session = Depends(get_db),
    current_user: User = Depends(require_role(DRRMO)),
):
    req = db.get(LogisticsRequest, request_id)
    if req is None:
        raise HTTPException(status_code=404, detail="Logistics request not found")
    if req.status != "Accepted":
        raise HTTPException(status_code=400, detail="Only accepted (scheduled) requests can be completed")
    row = request_rows(db, [req])[0]
    done = payload.completed_at or datetime.now(timezone.utc)
    summary = (f"Completed {done:%Y-%m-%d}: {payload.summary}. "
               f"Goods: {', '.join(row['goods']) or '-'}. Destination: {row['destination'] or '-'}.")
    req.status = "Completed"
    req.notes = f"{req.notes}\n{summary}" if req.notes else summary
    log_action(db, current_user, "COMPLETE LOGISTICS SUPPORT", "logistics_requests", request_id,
               old={"status": "Accepted"}, new={"status": "Completed", "summary": summary})
    db.flush()
    return request_rows(db, [req])[0]


@router.get("/dashboard")
def drrmo_dashboard(
    db: Session = Depends(get_db),
    current_user: User = Depends(require_role(DRRMO)),
):
    rows = request_rows(db, db.query(LogisticsRequest).all())
    return {
        "total_requests": len(rows),
        "pending_requests": sum(1 for r in rows if r["stage"] == "Pending"),
        "scheduled": sum(1 for r in rows if r["stage"] == "Accepted"),
        "in_transit": sum(1 for r in rows if r["stage"] == "In Transit"),
        "completed": sum(1 for r in rows if r["stage"] == "Completed"),
        "declined": sum(1 for r in rows if r["stage"] == "Declined"),
    }