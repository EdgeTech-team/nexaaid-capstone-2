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
from schemas.logistics_request_schema import (
    AcceptLogisticsRequest, DeclineLogisticsRequest, LogisticsRequestResponse
)

router = APIRouter(prefix="/drrmo", tags=["drrmo"])

DRRMO = "DRRMO Logistics Support"


def request_rows(db: Session, requests) -> list:
    """Requests with their delivery details, used by DRRMO and CSWS screens."""
    deliveries = {
        d.delivery_id: d
        for d in db.query(Delivery).filter(
            Delivery.delivery_id.in_([r.delivery_id for r in requests] or [-1])
        ).all()
    }
    items = {i.item_id: i for i in db.query(Item).all()}
    types = {t.disaster_type_id: t.type_name for t in db.query(DisasterType).all()}
    brgys = {b.barangay_id: b.barangay_name for b in db.query(Barangay).all()}
    reports = {r.report_id: r for r in db.query(DisasterReport).filter(
        DisasterReport.report_id.in_([d.report_id for d in deliveries.values()] or [-1])).all()}
    out = []
    for r in requests:
        d = deliveries.get(r.delivery_id)
        rep = reports.get(d.report_id) if d else None
        stage = r.status
        if r.status == "Accepted" and d is not None and d.status in ("In Transit", "Delivered"):
            stage = "In Transit"  # UC-DR2: in-transit support, from the delivery's tracking status
        out.append({
            "request_id": r.request_id,
            "delivery_id": r.delivery_id,
            "status": r.status,
            "stage": stage,
            "scheduled_date": r.scheduled_date,
            "notes": r.notes,
            "created_at": r.created_at,
            "delivery_status": d.status if d else None,
            "destination": brgys.get(d.destination_barangay_id) if d else None,
            "report_label": (f"#{rep.report_id} {types.get(rep.disaster_type_id, 'Disaster')} - "
                             f"{brgys.get(rep.barangay_id, 'Barangay')}") if rep else None,
            "goods": [
                f"{i.quantity} {items[i.item_id].unit_of_measure} {items[i.item_id].item_name}"
                if i.item_id in items else f"{i.quantity} item(s)"
                for i in (d.items if d else [])
            ],
        })
    return out


@router.get("/requests")
def list_requests(
    status: Optional[str] = Query(default=None, description="Pending / Accepted / Declined / Completed"),
    db: Session = Depends(get_db),
    current_user: User = Depends(require_role(DRRMO)),
):
    query = db.query(LogisticsRequest)
    if status:
        query = query.filter(LogisticsRequest.status == status)
    return request_rows(db, query.order_by(LogisticsRequest.request_id.desc()).all())


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
    req.scheduled_date = payload.scheduled_date
    req.assigned_to_user_id = current_user.user_id
    if payload.notes:
        req.notes = payload.notes
    log_action(db, current_user, "ACCEPT LOGISTICS REQUEST", "logistics_requests", request_id,
               old={"status": "Pending"},
               new={"status": "Accepted", "scheduled_date": payload.scheduled_date.isoformat()})

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
