"""
app/schemas/delivery.py
Pydantic schemas for Module 3.10 - Delivery Tracking & Receipt Confirmation.
"""

from datetime import datetime
from decimal import Decimal
from typing import Dict, List, Optional, Literal
from pydantic import BaseModel, ConfigDict, Field

from schemas.logistics_request_schema import TransportNeeds

DeliveryStatus = Literal["Preparing", "In Transit", "Delivered", "Confirmed", "Cancelled"]

# J1 / NF-009: why the barangay's count differs from what CSWS sent.
# "Over" only when more arrived; the other three only when fewer arrived
# (checked in api/v1/deliveries.py and by chk_receipt_items_reason_fits).
DiscrepancyReason = Literal["Short", "Damaged", "Wrong item", "Over"]
SHORT_REASONS = ("Short", "Damaged", "Wrong item")
OVER_REASON = "Over"

# Largest value a PostgreSQL INTEGER column holds.
MAX_COUNT = 2_147_483_647

# Delivery items

class DeliveryItemCreate(BaseModel):
    item_id: int
    quantity: int = Field(gt=0)

class DeliveryItemResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    delivery_item_id: int
    item_id: int
    quantity: int
    # Readable names (filled by the list endpoint; None elsewhere).
    item_name: Optional[str] = None
    unit: Optional[str] = None
    # J1 / NF-009: what the barangay counted on this line. None until the
    # barangay confirms, and for receipts saved before counting started
    # (those keep the sent quantity).
    received_quantity: Optional[int] = None
    discrepancy_reason: Optional[DiscrepancyReason] = None


# delivery

class DeliveryCreate(BaseModel):
    """CSWS Main office creates a delivery against an already-validated
    report. handled_by_user_id comes form authenticated user, not the client. Starts at status='Preparing' - not settable her."""

    report_id: int
    destination_barangay_id: int
    destination_sitio_id: Optional[int] = None
    delivery_date: datetime
    # Empty = every acknowledged donation of the report that has not gone
    # out yet (Oct 13; what the app sends). Typed lines are still accepted.
    items: List[DeliveryItemCreate] = []
    # Oct 15: the donation entries (batch references) that go, each whole.
    # Left out = every acknowledged entry of the report.
    batch_references: Optional[List[str]] = None
    # "Needs DRRMO transport?" (UC-CM2 alt 3a): also ask DRRMO, in the same
    # save. Trucks / volunteers / pushcarts as in POST /logistics/requests.
    transport: Optional[TransportNeeds] = None


class DeliveryBatchAdvance(BaseModel):
    """Mark several deliveries On the way at once (same rules as one by one;
    all or nothing)."""
    delivery_ids: List[int] = Field(..., min_length=1, max_length=50)

class DeliveryResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    delivery_id: int
    report_id: int
    destination_barangay_id: int
    destination_sitio_id: Optional[int] = None
    handled_by_user_id: int
    status: DeliveryStatus
    delivery_date: datetime
    created_at: datetime
    items: List[DeliveryItemResponse] = []
    # Readable names and the trip it travels on (None = a delivery on its own).
    report_label: Optional[str] = None
    destination_barangay_name: Optional[str] = None
    trip_id: Optional[int] = None
    stop_order: Optional[int] = None
    # Set when CSWS cancelled it (api/v1/delivery_problems.py).
    cancelled_at: Optional[datetime] = None
    cancel_reason: Optional[str] = None
    # When each step was reached, e.g. {"Preparing": ..., "In Transit": ...}
    # (services/delivery_views.py status_times).
    status_times: Optional[Dict[str, datetime]] = None
    # J1 / NF-009: the barangay counted a different quantity on a line.
    has_discrepancy: bool = False


#receipt confirmation

class ReceiptItemCount(BaseModel):
    """J1 / NF-009: the barangay's count for one delivery line. There is no
    default: the count field starts empty and must be filled in."""
    delivery_item_id: int
    received_quantity: int = Field(ge=0, le=MAX_COUNT)
    discrepancy_reason: Optional[DiscrepancyReason] = None
    discrepancy_note: Optional[str] = Field(default=None, max_length=500)


class ReceiptConfirm(BaseModel):
    """Body for Barangay receiving representative confirming a delivery. received_by_user_id
    comes from the authenticated user.

    J1 / NF-009: one count for every line of the delivery (items). A line
    that differs from what CSWS sent needs a discrepancy_reason.
    """
    items: List[ReceiptItemCount] = Field(..., min_length=1)
    remarks: Optional[str] = None


class TripDeliveryCounts(BaseModel):
    """J1 / NF-009: the counts for one delivery at a trip stop."""
    delivery_id: int
    items: List[ReceiptItemCount] = Field(..., min_length=1)


class TripReceiptConfirm(BaseModel):
    """POST /trips/{id}/confirm-receipt: counts for every delivery that
    arrived at the rep's barangay. A remarks-only body is refused (422).
    J3 adds the handover code and signature for the stop."""
    deliveries: List[TripDeliveryCounts] = Field(..., min_length=1)
    remarks: Optional[str] = None


class ReceiptItemResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    receipt_item_id: int
    delivery_item_id: int
    expected_quantity: int
    received_quantity: int
    discrepancy_reason: Optional[DiscrepancyReason] = None
    discrepancy_note: Optional[str] = None


class ReceiptResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    receipt_id: int
    delivery_id: int
    received_by_user_id: int
    received_at: datetime
    remarks: Optional[str]
    # J1 / NF-009: empty for receipts saved before counting started.
    items: List[ReceiptItemResponse] = []
    has_discrepancy: bool = False

# Fulfillment (read-only from this module's perspective — recalculated
# automatically, never edited directly through the API)

class ReportFulfillmentResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    fulfillment_id: int
    report_id: int
    total_items_needed: int
    total_items_delivered: int
    fulfillment_percentage: Decimal
    verification_status: Literal["Not Started", "Partial", "Complete"]
    verified_by_user_id: Optional[int]
    verified_at: Optional[datetime]

class ReceiptConfirmResponse(BaseModel):
    """Returned after confirming a receipt - shows the receipt itself, the delivery's new status and
    the recalculated fulfillment."""

    receipt: ReceiptResponse
    delivery: DeliveryResponse
    fulfillment: ReportFulfillmentResponse
