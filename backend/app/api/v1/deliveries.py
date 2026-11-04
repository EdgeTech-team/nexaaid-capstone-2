"""
app/api/v1/deliveries.py
module 3.10 - Delivery Tracking & Receipt Confirmation (Mariquit)

ASSUMPTIONS TO VERIFY (same caveats as api/v1/reports.py): 
-require_role/get_current_user shape-see the note in reports.py.
-Role names ("csws_main office", "barangay_receiving_rep", "admin")
are placeholders- swap for real RBAC role names once Known.
- confirm_receipt's barangay-match check (alt flow 3a: "delivery
  record can't be matched to assigned barangay") uses
  users.assigned_barangay_id via core.auth.barangay_scope(). Barangay
  Receiving Representatives also only list/see deliveries to that barangay.
"""

from datetime import date, datetime, timedelta, timezone
from decimal import Decimal
from types import SimpleNamespace
from typing import List, Optional

from fastapi import APIRouter, Depends, HTTPException, Query, status 
from sqlalchemy.orm import Session, joinedload

from core.database import get_db
from core.notifications import notify_event_many, user_ids_with_role
from models.report import DisasterReport
from core.auth import get_current_user, has_role, require_role, barangay_scope
from core.audit import log_action
from core.priority_engine import apply_priority
from services.fulfillment import recalculate as recalculate_fulfillment
from models.inventory_model import Inventory
from models.audit_log_model import AuditLog
from models.user_rbac_model import User
from models.report import DisasterReport, ReportFulfillment
from models.delivery import Delivery, DeliveryItem, Receipt
from models.logistics_request_model import LogisticsRequest
from api.v1.drrmo_router import (
    DRIVER, DRRMO, VEHICLE, complete_on_arrival, drrmo_to_tell, nice_time, note_line,
    open_request_for,
)
from api.v1.logistics_router import open_transport_request
from services.delivery_reminders import IN_TRANSIT_AFTER, PICKUP_LATE_AFTER, reached_at
from services.delivery_timing import response_times
from services.delivery_stock import check_stock, take_stock
from services.donation_expiry import MANILA, nice_date, now_utc, utc
from services.delivery_allocation import allocate_delivery, chosen_refs, ready_donations, ready_lines
from services.delivery_notices import tell_barangay_prepared, tell_donors, tell_status
from services.delivery_views import DELIVERY_SORTS, apply_delivery_filters, delivery_views, status_counts
from schemas.delivery import (
    DeliveryBatchAdvance,
    DeliveryCreate,
    DeliveryResponse,
    ReceiptConfirm,
    ReceiptConfirmResponse,
    ReportFulfillmentResponse,

)

router = APIRouter(prefix="/deliveries", tags=["deliveries"])

# Sequential order this module enforces ? see UC-37 alt flow 2a
# ("System prevents skipping stages"). 'Confirmed' is deliberately
# NOT reachable through advance_delivery ? only through
# confirm_receipt, since it represents the barangay's own action,
# not the CSWS Main Office's.

_STATUS_SEQUENCE =  ["Preparing", "In Transit", "Delivered", "Confirmed"]

MAIN_OFFICE = "CSWS Main Office"

# Plain staff words for each step in notices (Table 37). The statuses
# themselves stay as above.
STATUS_WORDS = {"Preparing": "Being packed", "In Transit": "On the way",
                "Delivered": "Arrived", "Confirmed": "Received by barangay"}


def check_drrmo_mover(db: Session, delivery: Delivery, req: LogisticsRequest, user) -> None:
    """Table 36 / Table 37: a delivery travelling with DRRMO is moved by the
    DRRMO user who accepted the request, or by the Administrator (who can
    step in when that person is away). Everyone else is told who has it.
    Team, Nov 4: the same holds for every other change while the request
    is open (new date, truck came back, cancel, undo; delivery_problems)."""
    if req.status == "Accepted" and (
            req.assigned_to_user_id == user.user_id or has_role(user, "admin")):
        return
    if has_role(user, DRRMO):
        if req.status == "Pending":
            raise HTTPException(status_code=409, detail="Accept the request first.")
        who = db.get(User, req.assigned_to_user_id) if req.assigned_to_user_id else None
        name = f"{who.first_name or ''} {who.last_name or ''}".strip() if who else ""
        raise HTTPException(
            status_code=403,
            detail=(f"Request #{req.request_id} was accepted by {name or 'another DRRMO user'}. "
                    "Only they or the Administrator can update this delivery."),
        )
    raise HTTPException(status_code=409, detail=_drrmo_has_it(db, delivery, req))


def _drrmo_has_it(db: Session, delivery: Delivery, req: LogisticsRequest) -> str:
    """UC-CM2 alt 3a: why CSWS can't change this delivery, in plain words.
    Team, Nov 4: once CSWS asks DRRMO, only DRRMO manages the delivery;
    CSWS gets it back when DRRMO declines or withdraws."""
    if req.status == "Pending":
        return (f"Delivery #{delivery.delivery_id} is waiting for DRRMO to accept request "
                f"#{req.request_id}. Until DRRMO answers, only DRRMO can change it. "
                "If DRRMO declines, it comes back to you.")
    who = db.get(User, req.assigned_to_user_id) if req.assigned_to_user_id else None
    full = f"{who.first_name or ''} {who.last_name or ''}".strip() if who else ""
    name = f" ({full})" if full else ""
    return (f"Delivery #{delivery.delivery_id} goes with DRRMO{name}, request #{req.request_id}. "
            "Only DRRMO updates it now: On the way at pickup, Arrived at the barangay. "
            "If DRRMO can no longer do it, they withdraw and it comes back to you.")

# Create ? CSWS Main Office Representative creates a delivery + its items

@router.post ("/", response_model=DeliveryResponse, status_code=status.HTTP_201_CREATED)
def create_delivery(
    payload: DeliveryCreate,
    db: Session = Depends(get_db),
    current_user=Depends(require_role("csws_main_office", "admin")),
):

  report = db.get (DisasterReport,payload.report_id)
  if not report:
    raise HTTPException(status_code=404, detail="Report not found")
  if report.status != "Validated":
    raise HTTPException(status_code=409, detail="Only validated reports can receive deliveries")

  # Goods are released from this report's inventory (manuscript: "Inventory
  # is linked to specific report records"), so there must be enough stock.
  # services/delivery_stock.py: shared with trips, plain-language messages.
  # Oct 13 (team): no items = the whole report, i.e. every donation the CMO
  # acknowledged that has not gone out yet (the app always does this).
  # Oct 15: or only the entries Main Office kept ticked (each one whole).
  refs = None if payload.items else chosen_refs(db, payload.report_id, payload.batch_references)
  lines = payload.items or ready_lines(db, payload.report_id, refs)
  if not lines:
    raise HTTPException(
      status_code=409,
      detail="Nothing to send yet: no donation for this report has been acknowledged by the CMO.",
    )
  take_stock(check_stock(db, payload.report_id, lines))

  delivery = Delivery (
    report_id=payload.report_id,
    destination_barangay_id=payload.destination_barangay_id,
    destination_sitio_id=payload.destination_sitio_id,
    handled_by_user_id = current_user.user_id,
    status="Preparing",
    delivery_date=payload.delivery_date,
  )
  db.add(delivery)
  db.flush()

  for item_payload in lines: 
    db.add (
      DeliveryItem(
        delivery_id=delivery.delivery_id,
        item_id=item_payload.item_id,
        quantity=item_payload.quantity,
      
      )
    )

  db.flush()
  # Whose donations these goods are: first received, first sent.
  allocate_delivery(db, delivery, refs)
  log_action(db, current_user, "PREPARE DELIVERY", "deliveries", delivery.delivery_id,
             new={"status": "Preparing", "items": [i.model_dump() for i in lines]})
  tell_barangay_prepared(db, [delivery])   # the barangay gets ready to receive
  if payload.transport is not None:
    # "Needs DRRMO transport?" (UC-CM2 alt 3a): asked in the same save, so
    # there is never a delivery that was meant to go with DRRMO but wasn't asked.
    open_transport_request(db, delivery, current_user, payload.transport)
  db.refresh(delivery)
  return delivery

@router.get("/ready/{report_id}")
def ready_to_send(
    report_id: int,
    db: Session = Depends(get_db),
    current_user=Depends(require_role("csws_main_office", "admin")),
):
  """Oct 13 (team): what the next delivery of this report carries, i.e.
  every donation the CMO acknowledged that has not gone out yet, and how
  many still wait for the CMO. Changes nothing."""
  if db.get(DisasterReport, report_id) is None:
    raise HTTPException(status_code=404, detail="Report not found")
  return ready_donations(db, report_id)


# List — staff, with filters

# Appendix H, Module 8.5: DRRMO also views delivery records (read only).
# Sorting and filtering (Oct 9): status (one, or several comma-separated),
# barangay, report, trip, delivery date range and a search box (delivery no.,
# report no., barangay or item name). Names come with each delivery so the
# app can show "Banilad" instead of an id.
_LIST_ROLES = ("csws_main_office", "admin", "barangay_receiving_rep", "drrmo logistics support")


@router.get("/",response_model=List[DeliveryResponse])
def list_deliveries(
  status_filter: Optional[str] = Query(default=None, alias="status"),
  barangay_id: Optional[int]  = Query(default=None),
  report_id: Optional[int] = Query(default=None),
  trip_id: Optional[int] = Query(default=None),
  date_from: Optional[date] = Query(default=None, description="Delivery date on or after (Philippine date)"),
  date_to: Optional[date] = Query(default=None, description="Delivery date on or before (Philippine date)"),
  q: Optional[str] = Query(default=None, max_length=100),
  sort: str = Query(default="newest", pattern="^(" + "|".join(DELIVERY_SORTS) + ")$"),
  skip: int = Query(default=0, ge=0),
  limit: int =Query(default=50, ge=1, le=200),
  db: Session = Depends(get_db),
  current_user=Depends(require_role(*_LIST_ROLES)),

):
    query = (db.query(Delivery).options(joinedload(Delivery.items))
             .filter(Delivery.deleted_at.is_(None)))
    own_barangay = barangay_scope(current_user)
    if own_barangay is not None:
       query = query.filter(Delivery.destination_barangay_id == own_barangay)
    query = apply_delivery_filters(
       db, query, status=status_filter, barangay_id=barangay_id, report_id=report_id,
       trip_id=trip_id, date_from=date_from, date_to=date_to, q=q, sort=sort)
    return delivery_views(db, query.offset(skip).limit(limit).all())


@router.get("/counts")
def delivery_counts(
  barangay_id: Optional[int] = Query(default=None),
  report_id: Optional[int] = Query(default=None),
  db: Session = Depends(get_db),
  current_user=Depends(require_role(*_LIST_ROLES)),
):
    """How many deliveries are in each status, for the filter chips
    ("In Transit (3)"). Same barangay scope as the list."""
    query = db.query(Delivery).filter(Delivery.deleted_at.is_(None))
    own_barangay = barangay_scope(current_user)
    if own_barangay is not None:
       query = query.filter(Delivery.destination_barangay_id == own_barangay)
    if barangay_id:
       query = query.filter(Delivery.destination_barangay_id == barangay_id)
    if report_id:
       query = query.filter(Delivery.report_id == report_id)
    return status_counts(query)

# "Needs your action" (Phase 6, Table 36 / 37): what CSWS Main Office or
# DRRMO should do next, as counts with the matching ids. Zero counts are left
# out, so an empty list means "All caught up".
@router.get("/needs-action")
def needs_action(
    db: Session = Depends(get_db),
    current_user=Depends(require_role("csws_main_office", "admin", DRRMO)),
):
    now = now_utc()
    if has_role(current_user, DRRMO):
        items = _drrmo_actions(db, current_user, now)
    else:
        items = _csws_actions(db, now)
    items = [{**i, "count": len(i["ids"])} for i in items if i["ids"]]
    return {"items": items, "all_caught_up": not items}


def _csws_actions(db: Session, now) -> list:
    live = (db.query(Delivery)
            .filter(Delivery.deleted_at.is_(None),
                    Delivery.status.in_(("Preparing", "In Transit", "Delivered"))).all())
    latest = {}   # delivery_id -> its newest DRRMO request
    for r in (db.query(LogisticsRequest)
              .filter(LogisticsRequest.delivery_id.in_([d.delivery_id for d in live] or [-1]))
              .order_by(LogisticsRequest.request_id)):
        latest[r.delivery_id] = r
    on_road_since = reached_at(db, [d.delivery_id for d in live if d.status == "In Transit"],
                               "In Transit")
    packing, declined, stuck, arrived = [], [], [], []
    for d in live:
        r, did = latest.get(d.delivery_id), d.delivery_id
        if d.status == "Preparing":
            if r is not None and r.status == "Declined":
                declined.append(did)
            elif r is None or r.status in ("Cancelled", "Completed"):
                packing.append(did)
            elif (r.status == "Accepted"
                  and now - utc(r.scheduled_date or d.delivery_date) >= PICKUP_LATE_AFTER):
                stuck.append(did)
        elif d.status == "In Transit":
            if did in on_road_since and now - on_road_since[did] >= IN_TRANSIT_AFTER:
                stuck.append(did)
        else:
            arrived.append(did)
    return [
        {"key": "packing", "label": "Being packed: send it or ask DRRMO",
         "view": "Preparing", "ids": packing},
        {"key": "declined", "label": "DRRMO said no: ask again or send it yourself",
         "view": "Preparing", "ids": declined},
        {"key": "stuck", "label": "Stuck: pickup is late, or on the way for over a day",
         "view": None, "ids": stuck},
        {"key": "arrived", "label": "Arrived: waiting for the barangay to confirm",
         "view": "Delivered", "ids": arrived},
    ]


def _drrmo_actions(db: Session, user, now) -> list:
    reqs = (db.query(LogisticsRequest)
            .filter(LogisticsRequest.status.in_(("Pending", "Accepted"))).all())
    ds = {d.delivery_id: d for d in db.query(Delivery).filter(
        Delivery.delivery_id.in_([r.delivery_id for r in reqs if r.delivery_id] or [-1]))}
    today = now.astimezone(MANILA).date()

    def day(r):
        if r.request_type == "Pickup":
            return r.pickup_date
        d = ds.get(r.delivery_id)
        when = utc(r.scheduled_date or (d.delivery_date if d else None))
        return when.astimezone(MANILA).date() if when else None

    mine = [r for r in reqs if r.status == "Accepted" and r.assigned_to_user_id == user.user_id]
    return [
        {"key": "new", "label": "New requests to accept or decline", "view": "Pending",
         "ids": [r.request_id for r in reqs if r.status == "Pending"]},
        {"key": "today", "label": "Pickups scheduled for today", "view": "Accepted",
         "ids": [r.request_id for r in mine if day(r) == today and (
             r.request_type == "Pickup"
             or (r.delivery_id in ds and ds[r.delivery_id].status == "Preparing"))]},
        {"key": "on_the_way", "label": "On the way with you: mark Arrived at the barangay",
         "view": "In Transit",
         "ids": [r.request_id for r in mine
                 if r.delivery_id in ds and ds[r.delivery_id].status == "In Transit"]},
    ]


# Retrieve one

@router.get("/{delivery_id}", response_model=DeliveryResponse)
def get_delivery(
   delivery_id: int,
   db: Session= Depends(get_db),
    current_user= Depends(require_role("csws_main_office", "admin", "barangay_receiving_rep", "DRRMO Logistics Support")),):
  delivery =(
     db.query(Delivery)
     .options(joinedload(Delivery.items))
     .filter(Delivery.delivery_id == delivery_id)
     .first()
  )
  own_barangay = barangay_scope(current_user)
  if (not delivery or delivery.deleted_at is not None
          or (own_barangay is not None and delivery.destination_barangay_id != own_barangay)):
     raise HTTPException(status_code=404, detail="Delivery not found")
  return delivery


# Delete (testing, Oct 27): CSWS clears finished deliveries from the list.
# Only Cancelled (goods already back in stock) or Confirmed (the barangay
# received them). A soft delete: the row, its receipt and its quantities
# stay, so fulfillment, donor history and the audit log are unchanged.
_DELETABLE = ("Cancelled", "Confirmed")


@router.delete("/{delivery_id}", status_code=status.HTTP_204_NO_CONTENT)
def delete_delivery(
    delivery_id: int,
    db: Session = Depends(get_db),
    current_user=Depends(require_role("csws_main_office", "admin")),
):
    delivery = db.get(Delivery, delivery_id)
    if not delivery or delivery.deleted_at is not None:
        raise HTTPException(status_code=404, detail="Delivery not found")
    if delivery.status not in _DELETABLE:
        raise HTTPException(
            status_code=409,
            detail=(f"Delivery #{delivery.delivery_id} is {delivery.status}. Only cancelled "
                    "or confirmed deliveries can be deleted."),
        )
    delivery.deleted_at = now_utc()
    delivery.deleted_by_user_id = current_user.user_id
    log_action(db, current_user, "DELETE DELIVERY", "deliveries", delivery.delivery_id,
               old={"status": delivery.status}, new={"deleted": True})
    db.commit()


# Advance status — CSWS Main Office moves it one step forward, in order
@router.post("/{delivery_id}/advance", response_model=DeliveryResponse)
def advance_delivery(
    delivery_id: int,
    db: Session = Depends(get_db),
    current_user=Depends(require_role("csws_main_office", "admin")),
):
    delivery = db.get(Delivery, delivery_id)

    if not delivery:
        raise HTTPException(
            status_code=404,
            detail="Delivery not found"
        )
    move_to_next_status(db, delivery, current_user)
    db.flush()
    db.refresh(delivery)

    return delivery


@router.post("/advance-batch")
def advance_many(
    payload: DeliveryBatchAdvance,
    db: Session = Depends(get_db),
    current_user=Depends(require_role("csws_main_office", "admin")),
):
    """Phase 6: mark several deliveries On the way in one go. Same rules as
    one at a time (move_to_next_status). All or nothing: if one cannot go,
    nothing is changed (get_db rolls back) and the message says which."""
    moved = []
    for did in dict.fromkeys(payload.delivery_ids):
        d = db.get(Delivery, did)
        if d is None or d.deleted_at is not None:
            raise HTTPException(status_code=404,
                                detail=f"Nothing was changed: delivery #{did} was not found.")
        if d.status != "Preparing":
            raise HTTPException(
                status_code=409,
                detail=(f"Nothing was changed: delivery #{did} is "
                        f"{STATUS_WORDS.get(d.status, d.status).lower()}, not being packed."))
        try:
            move_to_next_status(db, d, current_user)
        except HTTPException as e:
            raise HTTPException(status_code=e.status_code,
                                detail=f"Nothing was changed. Delivery #{did}: {e.detail}")
        moved.append(did)
    db.flush()
    return {"moved": moved, "status": "In Transit"}


def move_to_next_status(db: Session, delivery: Delivery, current_user) -> Delivery:
    """One step forward (Preparing -> In Transit -> Delivered) with the
    timestamped history and notifications. Used by advance_delivery and by
    trips (api/v1/trips.py) so both behave the same. Does not commit."""
    # 'Confirmed' is the last stage and is only reached via
    # confirm_receipt below — never through this endpoint.
    if delivery.status == "Cancelled":
        raise HTTPException(status_code=409, detail="This delivery was cancelled.")

    if delivery.status == "Delivered":
        raise HTTPException(
            status_code=409,
            detail=(
                "Delivery is already 'Delivered'. Confirmation happens "
                "through the barangay's receipt confirmation, not here."
            ),
        )

    if delivery.status == "Confirmed":
        raise HTTPException(
            status_code=409,
            detail="Delivery is already Confirmed"
        )

    # Check if the current status is valid
    if delivery.status not in _STATUS_SEQUENCE:
        raise HTTPException(
            status_code=400,
            detail=f"Invalid delivery status: {delivery.status}"
        )

    current_index = _STATUS_SEQUENCE.index(delivery.status)

    # UC-CM2 alt 3a, advisor (Oct 24) + testing (Oct 27): once CSWS asked
    # DRRMO for transport, DRRMO moves the delivery (In Transit on pickup,
    # Delivered on arrival; drrmo_router picked_up / delivered). CSWS waits
    # while the request is Pending or Accepted, or cancels it to send the
    # goods itself. A Declined request no longer holds the delivery: CSWS
    # asks again or sends it (Table 36 alt 3a). Without a request, CSWS
    # Main Office moves it as before.
    carrying = open_request_for(db, delivery.delivery_id)
    if carrying is not None:
        check_drrmo_mover(db, delivery, carrying, current_user)

    # Testing feedback (Oct 20): the truck can't leave before the day it is
    # scheduled for (trips start through here too, so "Arrived" can't come
    # first either). Leaving earlier means changing the date first.
    if delivery.status == "Preparing" and delivery.delivery_date is not None:
        leaves = utc(delivery.delivery_date)
        if now_utc().astimezone(MANILA).date() < leaves.astimezone(MANILA).date():
            raise HTTPException(
                status_code=409,
                detail=f"This delivery is scheduled to leave on {nice_date(leaves)}. "
                       f"If the truck is leaving now, change the date first.",
            )

    old_status = delivery.status
    delivery.status = _STATUS_SEQUENCE[current_index + 1]
    # Timestamped status history (UC-CM2 / delivery module step 3)
    log_action(db, current_user, "UPDATE DELIVERY STATUS", "deliveries", delivery.delivery_id,
               old={"status": old_status}, new={"status": delivery.status})
   
    # Table 36 / Table 37: the goods reached the barangay, so DRRMO's
    # support is done; its summary is recorded and both offices are told.
    told = set()
    if delivery.status == "Delivered" and carrying is not None:
        told = complete_on_arrival(db, carrying, current_user)

    report = db.get(DisasterReport, delivery.report_id)
    recipients = set(user_ids_with_role(
        db, ["Barangay Receiving Representative"],
        barangay_id=delivery.destination_barangay_id))
    # Scope 7.5 / Table 36: every CSWS Main Office user follows each step.
    # DRRMO only when this delivery involves it: all DRRMO while the request
    # waits, then only the DRRMO user who accepted it (drrmo_to_tell).
    recipients |= set(user_ids_with_role(db, [MAIN_OFFICE]))
    recipients |= drrmo_to_tell(db, delivery.delivery_id)
    if report:
        recipients.add(report.user_id)
    recipients.discard(current_user.user_id)
    # One notice per person: whoever just heard "support completed" (it says
    # the goods arrived) does not also get "Delivery update".
    recipients -= told
    notify_event_many(db, recipients, "delivery_status_changed", "delivery",
                      delivery.delivery_id,
                      title=f"Delivery #{delivery.delivery_id}",
                      status=STATUS_WORDS.get(delivery.status, delivery.status))
    tell_status(db, delivery)   # donors follow their donation (Oct 17)
    return delivery



# Undo (Phase 7, Table 37): a wrong tap can be taken back within
# UNDO_WINDOW by the person who made the step. Never once the barangay
# confirmed receipt (that is the barangay's own record, UC-B1).
UNDO_WINDOW = timedelta(minutes=10)
# Audit actions that set a delivery's status; the newest is "the last step".
_STEP_ACTIONS = ("PREPARE DELIVERY", "UPDATE DELIVERY STATUS", "RETURN TO OFFICE",
                 "CONFIRM RECEIPT", "CANCEL DELIVERY", "UNDO DELIVERY STEP")


@router.post("/{delivery_id}/undo")
def undo_last_step(
    delivery_id: int,
    db: Session = Depends(get_db),
    current_user=Depends(require_role("csws_main_office", "admin", DRRMO)),
):
    d = db.get(Delivery, delivery_id)
    if d is None or d.deleted_at is not None:
        raise HTTPException(status_code=404, detail="Delivery not found")
    if d.status == "Confirmed":
        raise HTTPException(status_code=409,
                            detail="The barangay already confirmed receipt, so this can't be undone.")
    if d.status == "Cancelled":
        raise HTTPException(status_code=409, detail="This delivery was cancelled.")
    # Team, Nov 4: while DRRMO has the delivery, CSWS changes nothing.
    carrying = open_request_for(db, delivery_id)
    if carrying is not None and not has_role(current_user, DRRMO, "admin"):
        raise HTTPException(status_code=409, detail=_drrmo_has_it(db, d, carrying))
    last = (db.query(AuditLog)
            .filter(AuditLog.entity_type == "deliveries", AuditLog.entity_id == delivery_id,
                    AuditLog.action.in_(_STEP_ACTIONS))
            .order_by(AuditLog.log_id.desc()).first())
    previous = (last.old_value or {}).get("status") if last is not None else None
    if (last is None or last.action != "UPDATE DELIVERY STATUS"
            or (last.new_value or {}).get("status") != d.status or previous not in _STATUS_SEQUENCE):
        raise HTTPException(status_code=409, detail="There is no step to undo.")
    if last.user_id != current_user.user_id:
        raise HTTPException(status_code=403, detail="Only the person who made this step can undo it.")
    if now_utc() - utc(last.timestamp) > UNDO_WINDOW:
        raise HTTPException(status_code=409,
                            detail="A step can be undone within 10 minutes only.")

    if d.status == "Delivered":
        # Arriving had completed DRRMO's request (Table 36): open it again.
        req = (db.query(LogisticsRequest)
               .filter(LogisticsRequest.delivery_id == delivery_id,
                       LogisticsRequest.status == "Completed")
               .order_by(LogisticsRequest.request_id.desc()).first())
        if req is not None:
            req.status = "Accepted"
            req.notes = f"{req.notes}\nCompletion undone: the arrival was taken back."
            log_action(db, current_user, "UNDO LOGISTICS COMPLETION", "logistics_requests",
                       req.request_id, old={"status": "Completed"}, new={"status": "Accepted"})
    log_action(db, current_user, "UNDO DELIVERY STEP", "deliveries", delivery_id,
               old={"status": d.status}, new={"status": previous, "undid_log_id": last.log_id})
    d.status = previous

    report = db.get(DisasterReport, d.report_id)
    recipients = set(user_ids_with_role(db, ["Barangay Receiving Representative"],
                                        barangay_id=d.destination_barangay_id))
    recipients |= set(user_ids_with_role(db, [MAIN_OFFICE])) | drrmo_to_tell(db, delivery_id)
    if report:
        recipients.add(report.user_id)
    recipients.discard(current_user.user_id)
    who = f"{current_user.first_name or ''} {current_user.last_name or ''}".strip() or "staff"
    notify_event_many(db, recipients, "delivery_step_undone", "delivery", delivery_id,
                      title=f"Delivery #{delivery_id}", status=STATUS_WORDS[previous], who=who)
    db.flush()
    return {"delivery_id": delivery_id, "status": d.status}


@router.get("/timing/summary")
def timing_summary(
    db: Session = Depends(get_db),
    current_user=Depends(require_role("csws_main_office", "admin", DRRMO)),
):
    """Phase 7 dashboards (CSWS and DRRMO): average time from a request to
    DRRMO accepting it, and from On the way to Arrived, from the audit log."""
    return response_times(db)


# Confirm receipt — Barangay Receiving Representative

@router.post(
    "/{delivery_id}/confirm-receipt",
    response_model=ReceiptConfirmResponse,
    status_code=status.HTTP_201_CREATED,
)
def confirm_receipt(
   delivery_id: int,
   payload: ReceiptConfirm,
   db: Session = Depends(get_db),
   current_user=Depends(require_role("barangay_receiving_rep","admin")),
):
    delivery = (
      db.query(Delivery)
      .options(joinedload(Delivery.items))
      .filter(Delivery.delivery_id == delivery_id)
      .first()
    )
    if not delivery:
        raise HTTPException(status_code=404, detail="Delivery not found")

    # Alt flow 4a: acknowledgment blocked until the delivery has actually
    # arrived — i.e. status must already be 'Delivered'.

    if  delivery.status != "Delivered":
       raise HTTPException(
          status_code=409,
          detail=f"Cannot confirm receipt-delivery status is"
                  f"'{delivery.status}', must be delivered first",
    )

    # Alt flow 3a: delivery must match the confirming rep's assigned
    # barangay (users.assigned_barangay_id).
    own_barangay = barangay_scope(current_user)
    if own_barangay is not None and own_barangay != delivery.destination_barangay_id:
       raise HTTPException(
          status_code=403,
          detail="This delivery is not for your assigned barangay.",
       )

    receipt = Receipt(
       delivery_id=delivery.delivery_id,
       received_by_user_id=current_user.user_id,
       remarks=payload.remarks
    )

    db.add(receipt)
    delivery.status = "Confirmed"
    log_action(db, current_user, "CONFIRM RECEIPT", "deliveries", delivery.delivery_id,
               old={"status": "Delivered"}, new={"status": "Confirmed", "remarks": payload.remarks})
    # Testing feedback (Oct 20): confirming receipt is also the barangay's
    # acknowledgement (UC-B1 step 5), so the rep taps once. The
    # "receipt confirmed" notice below reaches the same people.
    log_action(db, current_user, "ACKNOWLEDGE AID", "deliveries", delivery.delivery_id,
               new={"acknowledged": True, "with_receipt": True})
    
    report = db.get(DisasterReport, delivery.report_id)
    recipients = set(user_ids_with_role(db, ["CSWS Main Office"],
                                        exclude_user_id=current_user.user_id))
    if report and report.user_id != current_user.user_id:
        recipients.add(report.user_id)
    notify_event_many(db, recipients, "delivery_receipt_confirmed", "delivery",
                      delivery.delivery_id, title=f"Delivery #{delivery.delivery_id}")
    tell_donors(db, delivery, "donation_barangay_confirmed")
    db.flush()

    fulfillment = _recalculate_fulfillment (
       db, report_id=delivery.report_id, verified_by_user_id=current_user.user_id
    )

    db.flush()
    db.refresh(receipt)
    db.refresh(delivery)
    db.refresh(fulfillment)

    return ReceiptConfirmResponse(receipt=receipt, delivery=delivery, fulfillment=fulfillment)

# Acknowledge — Barangay Receiving Representative (UC-B1 step 5).
# Since Oct 20 confirm-receipt records the acknowledgement too, so the app
# no longer calls this; kept for deliveries confirmed before that.
# Only allowed after receipt is confirmed (alt flow 4a). Stored in audit_logs.

@router.post("/{delivery_id}/acknowledge")
def acknowledge_delivery(
   delivery_id: int,
   db: Session = Depends(get_db),
   current_user=Depends(require_role("barangay_receiving_rep", "admin")),
):
    delivery = db.get(Delivery, delivery_id)
    own_barangay = barangay_scope(current_user)
    if not delivery or (own_barangay is not None and delivery.destination_barangay_id != own_barangay):
        raise HTTPException(status_code=404, detail="Delivery not found")
    if delivery.status != "Confirmed":
        raise HTTPException(status_code=409, detail="Confirm receipt first, then acknowledge")
    if _is_acknowledged(db, delivery_id):
        raise HTTPException(status_code=409, detail="Already acknowledged")
    log_action(db, current_user, "ACKNOWLEDGE AID", "deliveries", delivery_id,
               new={"acknowledged": True})
    # Oct 17 run-through: the final record of the delivery reaches CSWS Main
    # Office and the Disaster Unit member who reported the need.
    report = db.get(DisasterReport, delivery.report_id)
    recipients = set(user_ids_with_role(db, ["CSWS Main Office"], exclude_user_id=current_user.user_id))
    if report and report.user_id != current_user.user_id:
        recipients.add(report.user_id)
    barangay = delivery.destination_barangay.barangay_name if delivery.destination_barangay else "The barangay"
    notify_event_many(db, recipients, "delivery_acknowledged", "delivery", delivery_id,
                      title=f"Delivery #{delivery_id}", barangay=barangay)
    db.flush()
    return {"delivery_id": delivery_id, "acknowledged": True}


def _is_acknowledged(db: Session, delivery_id: int) -> bool:
    return db.query(AuditLog).filter(
        AuditLog.entity_type == "deliveries",
        AuditLog.entity_id == delivery_id,
        AuditLog.action == "ACKNOWLEDGE AID",
    ).first() is not None


# Status history with timestamps (who moved it, when)

@router.get("/{delivery_id}/history")
def delivery_history(
   delivery_id: int,
   db: Session = Depends(get_db),
   current_user=Depends(require_role("csws_main_office", "admin", "barangay_receiving_rep", "drrmo logistics support")),
):
    delivery = db.get(Delivery, delivery_id)
    own_barangay = barangay_scope(current_user)
    if not delivery or (own_barangay is not None and delivery.destination_barangay_id != own_barangay):
        raise HTTPException(status_code=404, detail="Delivery not found")
    rows = (
        db.query(AuditLog, User.first_name, User.last_name, User.email)
        .join(User, User.user_id == AuditLog.user_id)
        .filter(AuditLog.entity_type == "deliveries", AuditLog.entity_id == delivery_id)
        .order_by(AuditLog.log_id)
        .all()
    )
    return {
        "delivery_id": delivery_id,
        "status": delivery.status,
        "acknowledged": any(l.action == "ACKNOWLEDGE AID" for l, *_ in rows),
        "history": [
            # F-23(c): a staff display name, not their email, for barangay reps
            # and DRRMO. "{first} {last}" or the email only if both are blank.
            {"action": l.action, "old": l.old_value, "new": l.new_value,
             "by": f"{first or ''} {last or ''}".strip() or email, "at": l.timestamp}
            for l, first, last, email in rows
        ],
        "timeline": _timeline(db, delivery, [
            (l, f"{first or ''} {last or ''}".strip() or email) for l, first, last, email in rows]),
    }


def _timeline(db: Session, delivery: Delivery, rows: list) -> list:
    """Table 37 in staff words: Being packed -> Truck assigned (only when
    DRRMO carries it) -> On the way -> Arrived -> Received by barangay, each
    with when and who. A step is done when the delivery has reached it now
    (a truck that came back is not "On the way" any more)."""
    def latest(match):
        hits = [(log, by) for log, by in rows if match(log)]
        return hits[-1] if hits else (None, None)

    def moved_to(status):
        return lambda log: (log.action == "UPDATE DELIVERY STATUS"
                            and (log.new_value or {}).get("status") == status)

    reached = (_STATUS_SEQUENCE.index(delivery.status)
               if delivery.status in _STATUS_SEQUENCE else -1)

    def step(key, label, index, log, by, detail=None):
        return {"key": key, "label": label, "done": reached >= index,
                "at": log.timestamp if log is not None and reached >= index else None,
                "by": by if reached >= index else None, "detail": detail}

    packed, packed_by = latest(lambda log: log.action == "PREPARE DELIVERY")
    steps = [step("packed", STATUS_WORDS["Preparing"], 0, packed, packed_by)]
    if packed is None:   # older or trip deliveries: when the record was made
        steps[0]["at"] = delivery.created_at

    # Truck assigned: the DRRMO request carrying it (UC-DR1 step 5).
    req = (db.query(LogisticsRequest)
           .filter(LogisticsRequest.delivery_id == delivery.delivery_id,
                   LogisticsRequest.status.in_(("Pending", "Accepted", "Completed")))
           .order_by(LogisticsRequest.request_id.desc()).first())
    if req is not None:
        accepted = (db.query(AuditLog, User.first_name, User.last_name)
                    .join(User, User.user_id == AuditLog.user_id)
                    .filter(AuditLog.entity_type == "logistics_requests",
                            AuditLog.entity_id == req.request_id,
                            AuditLog.action == "ACCEPT LOGISTICS REQUEST")
                    .order_by(AuditLog.log_id.desc()).first())
        detail = "Waiting for DRRMO to accept"
        if req.status != "Pending":
            vehicle, driver = note_line(req.notes, VEHICLE), note_line(req.notes, DRIVER)
            detail = " · ".join(p for p in (
                f"DRRMO arriving {nice_time(req.scheduled_date or delivery.delivery_date)}",
                vehicle, f"Driver: {driver}" if driver else None) if p)
        steps.append({
            "key": "truck", "label": "Truck assigned", "done": req.status != "Pending",
            "at": accepted[0].timestamp if accepted and req.status != "Pending" else None,
            "by": f"{accepted[1] or ''} {accepted[2] or ''}".strip() or None if accepted else None,
            "detail": detail,
        })

    for key, status_name, index in (("on_the_way", "In Transit", 1), ("arrived", "Delivered", 2)):
        log, by = latest(moved_to(status_name))
        steps.append(step(key, STATUS_WORDS[status_name], index, log, by))
    log, by = latest(lambda log: log.action == "CONFIRM RECEIPT")
    steps.append(step("received", STATUS_WORDS["Confirmed"], 3, log, by))

    if delivery.status == "Cancelled":
        log, by = latest(lambda log: log.action == "CANCEL DELIVERY")
        steps.append({"key": "cancelled", "label": "Cancelled", "done": True,
                      "at": log.timestamp if log is not None else delivery.cancelled_at,
                      "by": by, "detail": delivery.cancel_reason})
    return steps



# Fulfillment recalculation — internal helper, not an endpoint

def _recalculate_fulfillment(
      db: Session,
      report_id: int,
      verified_by_user_id: int,
) -> ReportFulfillment:
  """Per-item fulfillment (Oct 2026): each need of the report is measured
  against the confirmed deliveries of THAT item, capped at 100%, and the
  report's percentage is the average (services/fulfillment.py). Old reports
  have one "General needs" line, which counts every item like before.

  Alt flow 5a: if the linked report is already closed/resolved, this
  still updates report_fulfillments; it never touches disaster_reports.status.
  """
  fulfillment = recalculate_fulfillment(db, report_id, verified_by_user_id)

  # Testing, Module 3: the priority depends on fulfillment, so recompute it
  # now. Before this it was set once, at validation, and never changed.
  report = db.get(DisasterReport, report_id)
  if report is not None and report.status == "Validated":
    old_level = report.priority_level
    apply_priority(report)
    if report.priority_level != old_level:
      log_action(db, SimpleNamespace(user_id=verified_by_user_id), "UPDATE PRIORITY", "disaster_reports",
                 report_id, old={"priority_level": old_level},
                 new={"priority_level": report.priority_level})
    db.flush()
  return fulfillment