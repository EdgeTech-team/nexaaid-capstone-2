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

# J2 / NF-015: exactly six ASCII digits ("\d" would also accept other
# scripts' digits).
HANDOVER_CODE_PATTERN = r"^[0-9]{6}$"

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


# J2 / NF-015: the handover code, shown once.

class HandoverCodeResponse(BaseModel):
    """POST /deliveries/{id}/handover-code (CSWS Main Office, or the DRRMO
    user on the linked request). The server keeps only a keyed hash, so the
    code is shown here once. A new code replaces the old one; deliveries of
    the same trip stop share it."""
    delivery_ids: List[int]
    handover_code: str
    created_at: datetime


#receipt confirmation

class ReceiptItemCount(BaseModel):
    """J1 / NF-009: the barangay's count for one delivery line. There is no
    default: the count field starts empty and must be filled in."""
    delivery_item_id: int
    received_quantity: int = Field(ge=0, le=MAX_COUNT)
    discrepancy_reason: Optional[DiscrepancyReason] = None
    discrepancy_note: Optional[str] = Field(default=None, max_length=500)


class ReceiptProof(BaseModel):
    """J2 / NF-015 (team agreement A2): proof of receipt, required on every
    new receipt. Missing or empty fields are refused (422).

    handover_code       the 6 digits the CSWS staff (or DRRMO) on site shows
    signer_name         full name of the Barangay Receiving Representative
    signer_position     e.g. "Barangay Secretary"
    signature_file_id   the signature PNG uploaded with purpose receipt_signature
    slip_photo_file_id  optional photo of the stamped paper slip (purpose
                        receipt_slip_photo); no photos of goods or people
    """
    model_config = ConfigDict(str_strip_whitespace=True)

    handover_code: str = Field(..., pattern=HANDOVER_CODE_PATTERN)
    signer_name: str = Field(..., min_length=2, max_length=150)
    signer_position: str = Field(..., min_length=2, max_length=100)
    signature_file_id: str = Field(..., min_length=1, max_length=36)
    slip_photo_file_id: Optional[str] = Field(default=None, min_length=1, max_length=36)


class ReceiptConfirm(ReceiptProof):
    """Body for Barangay receiving representative confirming a delivery. received_by_user_id
    comes from the authenticated user.

    J1 / NF-009: one count for every line of the delivery (items). A line
    that differs from what CSWS sent needs a discrepancy_reason.
    J2 / NF-015: plus the handover code, name, position and signature.
    """
    items: List[ReceiptItemCount] = Field(..., min_length=1)
    remarks: Optional[str] = None


class TripDeliveryCounts(BaseModel):
    """J1 / NF-009: the counts for one delivery at a trip stop."""
    delivery_id: int
    items: List[ReceiptItemCount] = Field(..., min_length=1)


class TripReceiptConfirm(ReceiptProof):
    """POST /trips/{id}/confirm-receipt: counts for every delivery that
    arrived at the rep's barangay, plus one handover code and one signature
    for the stop (J2 / NF-015, team decision: the counting half of J3 in J1,
    the code and signature half in J2). A remarks-only body is refused (422)."""
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
    # J2 / NF-015: no code here, ever; only whether it was verified.
    reference_no: Optional[str] = None
    signer_name: Optional[str] = None
    signer_position: Optional[str] = None
    handover_verified: bool = False

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


# J2 / NF-015: the read-only Acknowledgment Receipt
# (GET /deliveries/{id}/acknowledgment, services/acknowledgment.py).

class AcknowledgmentLine(BaseModel):
    """One item as every viewer sees it, donors included."""
    item_id: int
    item_name: str
    unit: Optional[str] = None
    # Packaging of the donations that went on this line, e.g.
    # "Sack (50 kg), Box"; None when none is recorded.
    packaging: Optional[str] = None
    expected_quantity: int                    # sent by CSWS
    received_quantity: Optional[int] = None   # counted by the barangay; None before J1
    discrepancy_reason: Optional[DiscrepancyReason] = None


class AcknowledgmentFullLine(AcknowledgmentLine):
    """Staff and the barangay also see the rep's note on a difference."""
    discrepancy_note: Optional[str] = None


class DonorAcknowledgment(BaseModel):
    """What a donor whose goods were on the delivery sees: the items, the
    barangay, the reference no. and the date. No signer, signature, report,
    code status, remarks, or other donors."""
    view: Literal["donor"] = "donor"
    reference_no: str
    delivery_id: int
    barangay_name: str
    received_at: datetime
    items: List[AcknowledgmentLine]


class Acknowledgment(BaseModel):
    """The full Acknowledgment Receipt: CSWS Main Office, the Disaster Unit,
    the Administrator, and the rep of that barangay. The signature and slip
    photo are fetched from the URLs below, with the same role check."""
    view: Literal["full"] = "full"
    reference_no: str
    delivery_id: int
    barangay_name: str
    received_at: datetime
    items: List[AcknowledgmentFullLine]
    report_id: int
    report_label: Optional[str] = None
    signer_name: Optional[str] = None
    signer_position: Optional[str] = None
    signature_url: Optional[str] = None
    slip_photo_url: Optional[str] = None
    handover_verified: bool = False
    has_discrepancy: bool = False
    remarks: Optional[str] = None


# J5 / NF-010 (team agreement A3): CSWS Main Office reviews a short delivery
# (the barangay counted less than was sent). Records the cause only: no
# stock is restored (office miscounts use the inventory adjustment), and
# fulfillment and priority are unchanged.

ShortfallCause = Literal["Damaged", "Lost in transit", "Miscount at office", "Miscount at barangay"]


class DiscrepancyReview(BaseModel):
    """POST /deliveries/{id}/discrepancy-review. cause is required; a cause
    not in the list is refused (422)."""
    model_config = ConfigDict(str_strip_whitespace=True)

    cause: ShortfallCause
    note: Optional[str] = Field(default=None, max_length=500)


class ShortLine(BaseModel):
    """One line the barangay counted short, with the rep's own reason."""
    delivery_item_id: int
    item_id: int
    item_name: str
    unit: Optional[str] = None
    expected_quantity: int
    received_quantity: int
    discrepancy_reason: Optional[DiscrepancyReason] = None
    discrepancy_note: Optional[str] = None


class ShortDelivery(BaseModel):
    """GET /deliveries/discrepancies: a Confirmed delivery with at least one
    short line, and CSWS Main Office's review of it (None until reviewed)."""
    delivery_id: int
    report_id: int
    report_label: Optional[str] = None
    barangay_name: str
    trip_id: Optional[int] = None
    received_at: datetime
    short_lines: List[ShortLine]
    cause: Optional[ShortfallCause] = None
    note: Optional[str] = None
    reviewed_at: Optional[datetime] = None
    reviewed_by: Optional[str] = None
