from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy.orm import Session
from core.database import get_db
from core.auth import require_role
from models.user_rbac_model import User
from models.logistics_request_model import LogisticsRequest
from schemas.logistics_request_schema import (
    AcceptLogisticsRequest, DeclineLogisticsRequest, LogisticsRequestResponse
)

router = APIRouter(prefix="/drrmo", tags=["drrmo"])


@router.get("/requests", response_model=list[LogisticsRequestResponse])
def list_pending_requests(
    db: Session = Depends(get_db),
    current_user: User = Depends(require_role("DRRMO Logistics Support")),
):
    return db.query(LogisticsRequest).filter(LogisticsRequest.status == "Pending").all()


@router.patch("/requests/{request_id}/accept", response_model=LogisticsRequestResponse)
def accept_request(
    request_id: int,
    payload: AcceptLogisticsRequest,
    db: Session = Depends(get_db),
    current_user: User = Depends(require_role("DRRMO Logistics Support")),
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

    db.commit()
    db.refresh(req)
    return req


@router.patch("/requests/{request_id}/decline", response_model=LogisticsRequestResponse)
def decline_request(
    request_id: int,
    payload: DeclineLogisticsRequest,
    db: Session = Depends(get_db),
    current_user: User = Depends(require_role("DRRMO Logistics Support")),
):
    req = db.query(LogisticsRequest).filter(LogisticsRequest.request_id == request_id).first()
    if req is None:
        raise HTTPException(status_code=404, detail="Logistics request not found")
    if req.status != "Pending":
        raise HTTPException(status_code=400, detail=f"Request is already {req.status}, cannot decline")

    req.status = "Declined"
    req.assigned_to_user_id = current_user.user_id
    req.notes = payload.notes

    db.commit()
    db.refresh(req)
    return req


@router.get("/dashboard")
def drrmo_dashboard(
    db: Session = Depends(get_db),
    current_user: User = Depends(require_role("DRRMO Logistics Support")),
):
    pending = db.query(LogisticsRequest).filter(LogisticsRequest.status == "Pending").count()
    scheduled = db.query(LogisticsRequest).filter(LogisticsRequest.status == "Accepted").count()
    completed = db.query(LogisticsRequest).filter(LogisticsRequest.status == "Completed").count()
    return {"pending_requests": pending, "scheduled": scheduled, "completed": completed}