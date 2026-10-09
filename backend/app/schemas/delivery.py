"""
app/schemas/delivery.py
Pydantic schemas for Module 3.10 - Delivery Tracking & Receipt Confirmation.
"""

from datetime import datetime
from decimal import Decimal
from typing import List, Optional, Literal
from pydantic import BaseModel, ConfigDict, Field

DeliveryStatus = Literal["Preparing", "In Transit", "Delivered", "Confirmed"]

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


# delivery

class DeliveryCreate(BaseModel):
    """CSWS Main office creates a delivery against an already-validated
    report. handled_by_user_id comes form authenticated user, not the client. Starts at status='Preparing' - not settable her."""

    report_id: int
    destination_barangay_id: int
    destination_sitio_id: Optional[int] = None
    delivery_date: datetime
    items: List[DeliveryItemCreate] = Field(min_length=1)

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


#receipt confirmation

class ReceiptConfirm(BaseModel):
    """Body for Barangay receiving representative confirming a delivery. received_by_user_id
    comes from the authenticated user.
    """
    remarks: Optional[str] = None

class ReceiptResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    receipt_id: int
    delivery_id: int
    received_by_user_id: int
    received_at: datetime
    remarks: Optional[str]

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