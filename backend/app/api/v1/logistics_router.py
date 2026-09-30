from fastapi import APIRouter, Depends, status
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
    delivery = Delivery(
        report_id=payload.report_id,
        destination_barangay_id=payload.destination_barangay_id,
        destination_sitio_id=payload.destination_sitio_id,
        handled_by_user_id=current_user.user_id,
        status="Preparing",
        delivery_date=payload.delivery_date,
    )
    db.add(delivery)
    db.flush()

    logistics_request = LogisticsRequest(
        delivery_id=delivery.delivery_id,
        requested_by_user_id=current_user.user_id,
        notes=payload.notes,
    )
    db.add(logistics_request)

    db.commit()
    db.refresh(logistics_request)
    return logistics_request