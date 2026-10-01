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

from datetime import datetime, timezone 
from decimal import Decimal
from typing import List, Optional

from fastapi import APIRouter, Depends, HTTPException, Query, status 
from sqlalchemy.orm import Session, joinedload

from core.database import get_db
from core.auth import get_current_user, require_role, barangay_scope
from core.audit import log_action
from models.inventory_model import Inventory
from models.audit_log_model import AuditLog
from models.user_rbac_model import User
from models.report import DisasterReport, ReportFulfillment
from models.delivery import Delivery, DeliveryItem, Receipt
from schemas.delivery import (
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
  stock = {}
  for item_payload in payload.items:
    inv = (
      db.query(Inventory)
      .filter(Inventory.item_id == item_payload.item_id, Inventory.report_id == payload.report_id)
      .first()
    )
    available = inv.quantity if inv else 0
    wanted = item_payload.quantity + stock.get(item_payload.item_id, (None, 0))[1]
    if wanted > available:
      raise HTTPException(
        status_code=409,
        detail=f"Not enough stock for item #{item_payload.item_id} in this report's inventory "
               f"(available {available}, requested {wanted})",
      )
    stock[item_payload.item_id] = (inv, wanted)
  for inv, qty in stock.values():
    inv.quantity -= qty

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

  for item_payload in payload.items: 
    db.add (
      DeliveryItem(
        delivery_id=delivery.delivery_id,
        item_id=item_payload.item_id,
        quantity=item_payload.quantity,
      
      )
    )

  db.flush()
  log_action(db, current_user, "PREPARE DELIVERY", "deliveries", delivery.delivery_id,
             new={"status": "Preparing", "items": [i.model_dump() for i in payload.items]})
  db.refresh(delivery)
  return delivery

# List — staff, with filters

# Appendix H, Module 8.5: DRRMO also views delivery records (read only).
@router.get("/",response_model=List[DeliveryResponse])
def list_deliveries(
  status_filter: Optional[str] = Query(default=None, alias="status"),
  barangay_id: Optional[int]  = Query(default=None),
  report_id: Optional[int] = Query(default=None),
  skip: int = Query(default=0, ge=0),
  limit: int =Query(default=50, ge=1, le=200),
  db: Session = Depends(get_db),
  current_user=Depends(require_role("csws_main_office", "admin", "barangay_receiving_rep", "drrmo logistics support")),

):
    query = db.query(Delivery).options(joinedload(Delivery.items))
    own_barangay = barangay_scope(current_user)
    if own_barangay is not None:
       query = query.filter(Delivery.destination_barangay_id == own_barangay)
    if status_filter:
       query = query.filter(Delivery.status == status_filter)
    if barangay_id: 
       query = query.filter(Delivery.destination_barangay_id == barangay_id)
    if report_id: 
        query= query.filter(Delivery.report_id == report_id)

    return (
       query.order_by(Delivery.created_at.desc())
       .offset(skip)
       .limit(limit)
       .all()
    )

# Retrieve one

@router.get("/{delivery_id}", response_model=DeliveryResponse)
def get_delivery(
   delivery_id: int,
   db: Session= Depends(get_db),
   current_user= Depends(require_role("csws_main_office", "admin", "barangay_receiving_rep")),
):
  delivery =(
     db.query(Delivery)
     .options(joinedload(Delivery.items))
     .filter(Delivery.delivery_id == delivery_id)
     .first()
  )
  own_barangay = barangay_scope(current_user)
  if not delivery or (own_barangay is not None and delivery.destination_barangay_id != own_barangay):
     raise HTTPException(status_code=404, detail="Delivery not found")
  return delivery


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

    # 'Confirmed' is the last stage and is only reached via
    # confirm_receipt below — never through this endpoint.

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

    old_status = delivery.status
    delivery.status = _STATUS_SEQUENCE[current_index + 1]
    # Timestamped status history (UC-CM2 / delivery module step 3)
    log_action(db, current_user, "UPDATE DELIVERY STATUS", "deliveries", delivery.delivery_id,
               old={"status": old_status}, new={"status": delivery.status})

    db.flush()
    db.refresh(delivery)

    return delivery



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
# Acknowledgment is separate from receipt confirmation and only allowed
# after it (delivery module alt flow 4a). Stored in audit_logs.

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
        db.query(AuditLog, User.email)
        .join(User, User.user_id == AuditLog.user_id)
        .filter(AuditLog.entity_type == "deliveries", AuditLog.entity_id == delivery_id)
        .order_by(AuditLog.log_id)
        .all()
    )
    return {
        "delivery_id": delivery_id,
        "status": delivery.status,
        "acknowledged": any(l.action == "ACKNOWLEDGE AID" for l, _ in rows),
        "history": [
            {"action": l.action, "old": l.old_value, "new": l.new_value,
             "by": email, "at": l.timestamp}
            for l, email in rows
        ],
    }


# Fulfillment recalculation — internal helper, not an endpoint

def _recalculate_fulfillment(
      db: Session, 
      report_id: int,
      verified_by_user_id: int,     
) -> ReportFulfillment: 
  """
  Sums delivered quantities across every CONFIRMED delivery this 
  report, and updates the report fulfillments record accordingly

  Alt flow 5a: if the linked report is already closed/resolved, this
  still updates report_fulfillments — it deliberately does NOT touch
  disaster_reports.status. Fulfillment and report status are tracked
  independently; this function only ever writes to report_fulfillments.
  """
  fulfillment =(
      db.query (ReportFulfillment)
      .filter(ReportFulfillment.report_id == report_id)
      .first()
   )

  if not fulfillment:
     raise HTTPException(
        status_code=409,
        detail="This report hs no fulfillment record yet- it may"
               "not have been validated. cannot delivered"
     ) 

  total_delivered =(
     db.query(DeliveryItem)
     .join(Delivery, DeliveryItem.delivery_id == Delivery.delivery_id)
     .filter(Delivery.report_id == report_id, Delivery.status == "Confirmed")
     .with_entities(DeliveryItem.quantity)
     .all()
  )

  total_delivered_quantity = sum(q for (q,) in total_delivered)

  fulfillment.total_items_delivered = total_delivered_quantity

  if fulfillment.total_items_needed > 0:
     pct = (Decimal(total_delivered_quantity)/ Decimal(fulfillment.total_items_needed)) * 100
     pct = min(pct, Decimal("100.00"))

  else: 
     pct = Decimal("0.00")
  fulfillment.fulfillment_percentage = round(pct, 2)

  if fulfillment.fulfillment_percentage <= 0:
     fulfillment_verification_status = "Not Started"

  elif fulfillment.fulfillment_percentage >= 100:
      fulfillment_verification_status = "Complete"

  else:
    fulfillment_verification_status ="Partial"

  fulfillment.verification_status = fulfillment_verification_status

  fulfillment.verified_by_user_id = verified_by_user_id
  fulfillment.verified_at = datetime.now(timezone.utc)
  
  db.flush()
  return fulfillment






