from fastapi import APIRouter, Depends, HTTPException, status
from core.audit import log_action
from sqlalchemy.orm import Session
from core.database import get_db
from core.auth import require_role
from models.user_rbac_model import User
from models.delivery import Delivery
from models.logistics_request_model import LogisticsRequest
from schemas.logistics_request_schema import SubmitLogisticsRequest, LogisticsRequestResponse
from core.notifications import notify_event_many, user_ids_with_role

router = APIRouter(prefix="/logistics", tags=["logistics"])


@router.post("/requests", response_model=LogisticsRequestResponse, status_code=status.HTTP_201_CREATED)
def submit_logistics_request(
    payload: SubmitLogisticsRequest,
    db: Session = Depends(get_db),
    current_user: User = Depends(require_role("CSWS Main Office")),
):
    # The request is for goods CSWS is already preparing (UC-CM2 3a), so it
    # attaches to that delivery instead of creating a new, empty one.
    delivery = db.get(Delivery, payload.delivery_id)
    if delivery is None:
        raise HTTPException(status_code=404, detail="Delivery not found")
    if delivery.status in ("Delivered", "Confirmed", "Cancelled"):
        raise HTTPException(status_code=409, detail=f"Delivery is already {delivery.status}")
    open_request = (
        db.query(LogisticsRequest)
        .filter(LogisticsRequest.delivery_id == delivery.delivery_id,
                LogisticsRequest.status.in_(["Pending", "Accepted"]))
        .first()
    )
    if open_request:
        raise HTTPException(status_code=409, detail="This delivery already has an open logistics request")

   
    logistics_request = LogisticsRequest(
        delivery_id=delivery.delivery_id,
        requested_by_user_id=current_user.user_id,
        notes=payload.needs_text(),   # I4: "Needs 2 trucks, 2 drivers, 3 volunteers"
    )
    db.add(logistics_request)
    db.flush()
    log_action(db, current_user, "REQUEST LOGISTICS SUPPORT", "logistics_requests",
               logistics_request.request_id,
               new={"delivery_id": delivery.delivery_id, "needs": logistics_request.notes})
    notify_event_many(db, user_ids_with_role(db, ["DRRMO Logistics Support"]),
                      "logistics_requested", "logistics_request",
                      logistics_request.request_id, title=f"delivery #{delivery.delivery_id}")

    db.commit()
    db.refresh(logistics_request)
    return logistics_request


@router.get("/requests")
def list_my_requests(
    db: Session = Depends(get_db),
    current_user: User = Depends(require_role("CSWS Main Office", "Administrator")),
):
    """CSWS sees whether DRRMO accepted, declined or completed each request
    (the "system notifies CSWS" steps of UC-DR1)."""
    from api.v1.drrmo_router import request_rows
    return request_rows(db, db.query(LogisticsRequest).order_by(LogisticsRequest.request_id.desc()).all())