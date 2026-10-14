"""When a delivery does not go as planned (team request, Oct 10, 2026).

Real problems CSWS meets: the date changes, the truck breaks down, a road is
closed, the barangay is not ready, DRRMO can no longer send a truck. Each
has one plain action, and every action keeps a record (audit log + reason)
and tells the people affected.

CSWS Main Office (or Administrator):
  POST /deliveries/{id}/reschedule        new date (Preparing / In Transit)
  POST /deliveries/{id}/return-to-office  truck came back, goods still with
                                          CSWS: In Transit -> Preparing
  POST /deliveries/{id}/cancel            delivery will not happen: goods go
                                          back to stock, status Cancelled
  POST /trips/{id}/reschedule             new date for every open delivery
  POST /trips/{id}/return-to-office       truck came back: every In Transit
                                          delivery of the trip -> Preparing
  POST /logistics/requests/{id}/cancel    CSWS no longer needs DRRMO's truck

DRRMO Logistics Support:
  POST /drrmo/requests/{id}/withdraw      accepted, but can no longer do it;
                                          CSWS is told and can ask again

Not allowed: changing anything once the goods are Delivered or Confirmed
(the barangay already has them).
"""
from datetime import datetime, timezone
from typing import Optional

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field, field_validator
from sqlalchemy.orm import Session

from core.audit import log_action
from core.auth import has_role, require_role
from core.database import get_db
from core.notifications import notify_event, notify_event_many, user_ids_with_role
from models.delivery import Delivery, DeliveryTrip
from models.inventory_model import Inventory
from models.logistics_request_model import LogisticsRequest
from models.user_rbac_model import User

router = APIRouter(tags=["Delivery problems"])

CSWS = ("csws_main_office", "admin")
DRRMO = "DRRMO Logistics Support"
DISASTER_UNIT = "CSWS Disaster Unit"
OPEN_REQUEST = ("Pending", "Accepted")


class Reason(BaseModel):
    reason: str = Field(min_length=3, max_length=500)

    @field_validator("reason")
    @classmethod
    def _strip(cls, v: str) -> str:
        v = v.strip()
        if len(v) < 3:
            raise ValueError("Please say what happened (at least 3 characters)")
        return v


class NewDate(BaseModel):
    delivery_date: datetime
    reason: Optional[str] = Field(default=None, max_length=500)

    @field_validator("delivery_date")
    @classmethod
    def _future(cls, v: datetime) -> datetime:
        if v.tzinfo is None:
            v = v.replace(tzinfo=timezone.utc)
        if v < datetime.now(timezone.utc).replace(hour=0, minute=0, second=0, microsecond=0):
            raise ValueError("Pick today or a later date")
        return v


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
def _delivery(db: Session, delivery_id: int) -> Delivery:
    d = db.get(Delivery, delivery_id)
    if d is None:
        raise HTTPException(status_code=404, detail="Delivery not found")
    return d


def _not_finished(d: Delivery) -> None:
    if d.status in ("Delivered", "Confirmed"):
        raise HTTPException(
            status_code=409,
            detail=f"Delivery #{d.delivery_id} already reached the barangay, so it can no longer be changed.",
        )
    if d.status == "Cancelled":
        raise HTTPException(status_code=409, detail=f"Delivery #{d.delivery_id} is already cancelled.")


def _people(db: Session, d: Delivery, exclude: int) -> set:
    """Barangay rep(s) of the destination, plus DRRMO if a truck was asked for."""
    out = set(user_ids_with_role(db, ["Barangay Receiving Representative"],
                                 barangay_id=d.destination_barangay_id))
    if db.query(LogisticsRequest).filter(LogisticsRequest.delivery_id == d.delivery_id).first():
        out |= set(user_ids_with_role(db, [DRRMO]))
    out.discard(exclude)
    return out


def _close_requests(db: Session, d: Delivery, user: User, reason: str) -> list:
    """Cancel DRRMO requests still open for this delivery."""
    closed = []
    for req in db.query(LogisticsRequest).filter(
        LogisticsRequest.delivery_id == d.delivery_id,
        LogisticsRequest.status.in_(OPEN_REQUEST),
    ):
        old = req.status
        req.status = "Cancelled"
        req.notes = f"{req.notes}\nCancelled by CSWS: {reason}" if req.notes else f"Cancelled by CSWS: {reason}"
        log_action(db, user, "CANCEL LOGISTICS REQUEST", "logistics_requests", req.request_id,
                   old={"status": old}, new={"status": "Cancelled", "reason": reason})
        closed.append(req.request_id)
    return closed


def _reschedule(db: Session, d: Delivery, when: datetime, reason: Optional[str], user: User) -> None:
    _not_finished(d)
    old = d.delivery_date
    d.delivery_date = when
    log_action(db, user, "RESCHEDULE DELIVERY", "deliveries", d.delivery_id,
               old={"delivery_date": old.isoformat() if old else None},
               new={"delivery_date": when.isoformat(), "reason": reason})
    notify_event_many(db, _people(db, d, user.user_id), "delivery_rescheduled", "delivery",
                      d.delivery_id, title=f"Delivery #{d.delivery_id}",
                      date=when.strftime("%b %d, %Y %I:%M %p"), reason=reason or "")


def _return(db: Session, d: Delivery, reason: str, user: User) -> None:
    if d.status != "In Transit":
        raise HTTPException(
            status_code=409,
            detail=f"Only a delivery that is on the road can come back. Delivery #{d.delivery_id} is {d.status}.",
        )
    d.status = "Preparing"
    log_action(db, user, "RETURN TO OFFICE", "deliveries", d.delivery_id,
               old={"status": "In Transit"}, new={"status": "Preparing", "reason": reason})
    notify_event_many(db, _people(db, d, user.user_id), "delivery_returned", "delivery",
                      d.delivery_id, title=f"Delivery #{d.delivery_id}", reason=reason)


# ---------------------------------------------------------------------------
# One delivery
# ---------------------------------------------------------------------------
@router.post("/deliveries/{delivery_id}/reschedule")
def reschedule_delivery(
    delivery_id: int,
    payload: NewDate,
    db: Session = Depends(get_db),
    current_user: User = Depends(require_role(*CSWS)),
):
    d = _delivery(db, delivery_id)
    _reschedule(db, d, payload.delivery_date, payload.reason, current_user)
    db.commit()
    return {"delivery_id": d.delivery_id, "delivery_date": d.delivery_date, "status": d.status}


@router.post("/deliveries/{delivery_id}/return-to-office")
def return_to_office(
    delivery_id: int,
    payload: Reason,
    db: Session = Depends(get_db),
    current_user: User = Depends(require_role(*CSWS)),
):
    """The truck came back with the goods (breakdown, road closed, nobody to
    receive). The delivery is Preparing again, so it can be sent later or
    cancelled. The goods are still counted as out of stock, because they are
    still loaded for this delivery."""
    d = _delivery(db, delivery_id)
    _return(db, d, payload.reason, current_user)
    db.commit()
    return {"delivery_id": d.delivery_id, "status": d.status}


@router.post("/deliveries/{delivery_id}/cancel")
def cancel_delivery(
    delivery_id: int,
    payload: Reason,
    db: Session = Depends(get_db),
    current_user: User = Depends(require_role(*CSWS)),
):
    """The delivery will not happen. Every item goes back to its report's
    stock, open DRRMO requests are cancelled, and the record is kept as
    Cancelled with the reason. A delivery on the road must come back first."""
    d = _delivery(db, delivery_id)
    _not_finished(d)
    if d.status == "In Transit":
        raise HTTPException(
            status_code=409,
            detail="This delivery is on the road. Tap \"Truck came back\" first, then cancel it.",
        )
    returned = []
    for line in d.items:
        inv = (db.query(Inventory)
               .filter(Inventory.item_id == line.item_id, Inventory.report_id == d.report_id).first())
        if inv is None:
            inv = Inventory(item_id=line.item_id, report_id=d.report_id, quantity=0)
            db.add(inv)
        inv.quantity += line.quantity
        returned.append({"item_id": line.item_id, "quantity": line.quantity})
    requests = _close_requests(db, d, current_user, payload.reason)
    d.status = "Cancelled"
    d.cancelled_at = datetime.now(timezone.utc)
    d.cancel_reason = payload.reason
    log_action(db, current_user, "CANCEL DELIVERY", "deliveries", d.delivery_id,
               old={"status": "Preparing"},
               new={"status": "Cancelled", "reason": payload.reason,
                    "returned_to_stock": returned, "cancelled_requests": requests})
    notify_event_many(db, _people(db, d, current_user.user_id), "delivery_cancelled", "delivery",
                      d.delivery_id, title=f"Delivery #{d.delivery_id}", reason=payload.reason)
    db.commit()
    return {"delivery_id": d.delivery_id, "status": d.status,
            "returned_to_stock": returned, "cancelled_requests": requests}


# ---------------------------------------------------------------------------
# A whole trip
# ---------------------------------------------------------------------------
def _trip(db: Session, trip_id: int) -> DeliveryTrip:
    t = db.get(DeliveryTrip, trip_id)
    if t is None:
        raise HTTPException(status_code=404, detail="Trip not found")
    return t


@router.post("/trips/{trip_id}/reschedule")
def reschedule_trip(
    trip_id: int,
    payload: NewDate,
    db: Session = Depends(get_db),
    current_user: User = Depends(require_role(*CSWS)),
):
    """New date for the trip and every delivery on it that has not arrived."""
    trip = _trip(db, trip_id)
    open_ = [d for d in trip.deliveries if d.status in ("Preparing", "In Transit")]
    if not open_:
        raise HTTPException(status_code=409, detail="Every stop of this trip is already done or cancelled.")
    trip.trip_date = payload.delivery_date
    for d in open_:
        _reschedule(db, d, payload.delivery_date, payload.reason, current_user)
    db.commit()
    return {"trip_id": trip.trip_id, "trip_date": trip.trip_date,
            "rescheduled_deliveries": [d.delivery_id for d in open_]}


@router.post("/trips/{trip_id}/return-to-office")
def trip_return_to_office(
    trip_id: int,
    payload: Reason,
    db: Session = Depends(get_db),
    current_user: User = Depends(require_role(*CSWS)),
):
    """The truck came back before finishing. Stops it had not reached go back
    to Preparing; stops already delivered stay delivered."""
    trip = _trip(db, trip_id)
    on_road = [d for d in trip.deliveries if d.status == "In Transit"]
    if not on_road:
        raise HTTPException(status_code=409, detail="No stop of this trip is on the road.")
    for d in on_road:
        _return(db, d, payload.reason, current_user)
    log_action(db, current_user, "TRIP RETURNED", "delivery_trips", trip.trip_id,
               new={"reason": payload.reason, "deliveries": [d.delivery_id for d in on_road]})
    db.commit()
    return {"trip_id": trip.trip_id, "returned_deliveries": [d.delivery_id for d in on_road]}


# ---------------------------------------------------------------------------
# DRRMO transport requests
# ---------------------------------------------------------------------------
def _request(db: Session, request_id: int) -> LogisticsRequest:
    r = db.get(LogisticsRequest, request_id)
    if r is None:
        raise HTTPException(status_code=404, detail="Logistics request not found")
    return r


@router.post("/logistics/requests/{request_id}/cancel")
def cancel_logistics_request(
    request_id: int,
    payload: Reason,
    db: Session = Depends(get_db),
    current_user: User = Depends(require_role(*CSWS, DISASTER_UNIT)),
):
    """CSWS no longer needs DRRMO's truck (found another vehicle, delivery
    cancelled or moved). DRRMO is told. The Disaster Unit cancels its own
    Door to Door pickup runs the same way."""
    req = _request(db, request_id)
    if has_role(current_user, DISASTER_UNIT) and not has_role(current_user, *CSWS):
        if req.request_type != "Pickup" or req.requested_by_user_id != current_user.user_id:
            raise HTTPException(status_code=403, detail="You can cancel only your own pickup requests.")
    if req.status not in OPEN_REQUEST:
        raise HTTPException(status_code=409, detail=f"This request is already {req.status}.")
    old = req.status
    req.status = "Cancelled"
    who = "Disaster Unit" if req.request_type == "Pickup" else "CSWS"
    req.notes = (f"{req.notes}\nCancelled by {who}: {payload.reason}" if req.notes
                 else f"Cancelled by {who}: {payload.reason}")
    log_action(db, current_user, "CANCEL LOGISTICS REQUEST", "logistics_requests", req.request_id,
               old={"status": old}, new={"status": "Cancelled", "reason": payload.reason})
    notify_event_many(db, user_ids_with_role(db, [DRRMO]), "logistics_cancelled",
                      "logistics_request", req.request_id,
                      title=req.title, reason=payload.reason)
    db.commit()
    return {"request_id": req.request_id, "status": req.status}


@router.post("/drrmo/requests/{request_id}/withdraw")
def withdraw_logistics_request(
    request_id: int,
    payload: Reason,
    db: Session = Depends(get_db),
    current_user: User = Depends(require_role(DRRMO)),
):
    """DRRMO accepted, then something changed (truck broke down, sent to an
    emergency). The request becomes Declined with the reason, so CSWS sees it
    and can ask again or arrange another vehicle (UC-DR1 alt 3a)."""
    req = _request(db, request_id)
    if req.status != "Accepted":
        raise HTTPException(
            status_code=409,
            detail="Only an accepted request can be withdrawn. Use Decline for a new one.",
        )
    d = db.get(Delivery, req.delivery_id) if req.delivery_id else None
    if d is not None and d.status in ("Delivered", "Confirmed"):
        raise HTTPException(status_code=409, detail="The goods already arrived, so this can no longer be withdrawn.")
    req.status = "Declined"
    req.notes = f"{req.notes}\nWithdrawn by DRRMO: {payload.reason}" if req.notes else f"Withdrawn by DRRMO: {payload.reason}"
    log_action(db, current_user, "WITHDRAW LOGISTICS SUPPORT", "logistics_requests", req.request_id,
               old={"status": "Accepted"}, new={"status": "Declined", "reason": payload.reason})
    notify_event(db, req.requested_by_user_id, "logistics_withdrawn", "logistics_request",
                 req.request_id, title=req.title, reason=payload.reason)
    db.commit()
    return {"request_id": req.request_id, "status": req.status}