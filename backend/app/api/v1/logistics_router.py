from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy.orm import Session
from core.database import get_db
from core.auth import require_role
from models.user_rbac_model import User
from models.delivery import Delivery
from models.logistics_request_model import LogisticsRequest
from schemas.logistics_request_schema import SubmitLogisticsRequest, LogisticsRequestResponse

router = APIRouter(prefix="/logistics", tags=["logistics"])


@router.post("/requests", response_model=LogisticsRequestResponse, status_code=status.HTTP_201_CREATED)
def submit_logistics_request(
    payload: SubmitLogisticsRequest,
    db: Session = Depends(get_db),
    current_user: User = Depends(require_role("CSWS Main Office")),  # CONFIRM: or "CSWS Disaster Unit"?
):
    # The request is for goods CSWS is already preparing (UC-CM2 3a), so it
    # attaches to that delivery instead of creating a new, empty one.
    delivery = db.get(Delivery, payload.delivery_id)
    if delivery is None:
        raise HTTPException(status_code=404, detail="Delivery not found")
    if delivery.status in ("Delivered", "Confirmed"):
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
        notes=payload.notes,
    )
    db.add(logistics_request)

    db.commit()
    db.refresh(logistics_request)
    return logistics_request
