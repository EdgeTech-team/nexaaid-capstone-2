from datetime import datetime, timedelta

from fastapi import APIRouter, Depends, HTTPException, status
from core.audit import log_action
from sqlalchemy.orm import Session
from core.database import get_db
from core.auth import has_role, require_role
from models.user_rbac_model import User
from models.delivery import Delivery
from models.logistics_request_model import LogisticsRequest
from models.physical_donation_model import PhysicalDonation
from schemas.logistics_request_schema import (
    SubmitLogisticsRequest, SubmitPickupLogisticsRequest, LogisticsRequestResponse,
)
from schemas.physical_donation_schema import (
    MANILA, decode_pickup_days, pickup_days_label, pickup_rules,
)
from core.notifications import notify_event_many, user_ids_with_role

router = APIRouter(prefix="/logistics", tags=["logistics"])

DISASTER_UNIT = "CSWS Disaster Unit"
OPEN = ("Pending", "Accepted")
_DAY_NAMES = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]


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
        request_type="Delivery",
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


@router.post("/pickup-requests", status_code=status.HTTP_201_CREATED)
def submit_pickup_request(
    payload: SubmitPickupLogisticsRequest,
    db: Session = Depends(get_db),
    current_user: User = Depends(require_role(DISASTER_UNIT)),
):
    """The CSWS Disaster Unit asks DRRMO to help with a Door to Door pickup
    run it planned on the pickup map (Oct 10 notes): one day, the donation
    entries in stop order, and what is needed (trucks, volunteers,
    pushcarts). Like UC-CM2 alt 3a, but for collecting instead of delivering.

    Checks: the day is a CSWS pickup day, today or later; every entry is a
    Door to Door donation still waiting to be collected; the donor said they
    are home that day; and no entry is already in another open pickup run."""
    rules = pickup_rules()
    today = datetime.now(MANILA).date()
    day = payload.pickup_date
    if day < today:
        raise HTTPException(status_code=422, detail="Choose today or a later date for the pickup run.")
    if day > today + timedelta(days=rules["max_days_ahead"]):
        raise HTTPException(status_code=422,
                            detail=f"Choose a date within {rules['max_days_ahead']} days.")
    if day.isoweekday() not in rules["days"]:
        raise HTTPException(status_code=422, detail=f"CSWS does pickups only on: {rules['label']}.")

    rows = (db.query(PhysicalDonation)
            .filter(PhysicalDonation.batch_reference.in_(payload.batch_references)).all())
    by_ref: dict = {}
    for r in rows:
        by_ref.setdefault(r.batch_reference, []).append(r)
    weekday = _DAY_NAMES[day.isoweekday() - 1]
    for ref in payload.batch_references:
        lines = by_ref.get(ref)
        if not lines:
            raise HTTPException(status_code=404, detail=f"No donation with reference {ref}.")
        first = lines[0]
        where = f" (near {first.pickup_landmark})" if first.pickup_landmark else ""
        if first.handover_method != "Door to Door":
            raise HTTPException(status_code=409, detail=f"{ref} is a Drop Off donation, not a pickup.")
        if not any(l.status == "Pending" for l in lines):
            raise HTTPException(status_code=409, detail=f"{ref}{where} has nothing left to collect.")
        days = decode_pickup_days(first.pickup_days)
        if days and day.isoweekday() not in days:
            raise HTTPException(
                status_code=409,
                detail=f"{ref}{where} is not available on {weekday}. "
                       f"The donor chose {pickup_days_label(first.pickup_days)}.",
            )

    for req in (db.query(LogisticsRequest)
                .filter(LogisticsRequest.request_type == "Pickup",
                        LogisticsRequest.status.in_(OPEN)).all()):
        taken = set(req.batch_list) & set(payload.batch_references)
        if taken:
            raise HTTPException(
                status_code=409,
                detail=f"{', '.join(sorted(taken))} is already in pickup request #{req.request_id}.",
            )

    needs = payload.needs_text()
    req = LogisticsRequest(
        request_type="Pickup",
        delivery_id=None,
        pickup_date=day,
        pickup_batches=",".join(payload.batch_references),
        requested_by_user_id=current_user.user_id,
        notes=f"{needs}\n{payload.notes}" if payload.notes else needs,
    )
    db.add(req)
    db.flush()
    log_action(db, current_user, "REQUEST PICKUP LOGISTICS SUPPORT", "logistics_requests",
               req.request_id,
               new={"pickup_date": day.isoformat(), "stops": payload.batch_references, "needs": needs})
    notify_event_many(db, user_ids_with_role(db, ["DRRMO Logistics Support"]),
                      "logistics_requested", "logistics_request", req.request_id, title=req.title)
    db.commit()
    db.refresh(req)
    from api.v1.drrmo_router import request_rows
    return request_rows(db, [req])[0]


@router.get("/requests")
def list_my_requests(
    db: Session = Depends(get_db),
    current_user: User = Depends(require_role("CSWS Main Office", "Administrator", DISASTER_UNIT)),
):
    """CSWS sees whether DRRMO accepted, declined or completed each request
    (the "system notifies CSWS" steps of UC-DR1). The Disaster Unit sees its
    Door to Door pickup runs."""
    from api.v1.drrmo_router import request_rows
    query = db.query(LogisticsRequest)
    if has_role(current_user, DISASTER_UNIT):
        query = query.filter(LogisticsRequest.request_type == "Pickup")
    return request_rows(db, query.order_by(LogisticsRequest.request_id.desc()).all())