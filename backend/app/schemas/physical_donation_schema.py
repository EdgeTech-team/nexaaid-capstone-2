from datetime import datetime
from decimal import Decimal
from typing import List, Literal, Optional

from pydantic import BaseModel, ConfigDict, Field, model_validator

HandoverMethod = Literal["Drop Off", "Door to Door"]


class GuestDonorInfo(BaseModel):
    full_name: str
    contact_number: str
    email: Optional[str] = None


class _ItemFields(BaseModel):
    """What one item line carries (UC-D2 step 6: item type, packaging size,
    quantity, estimated value)."""

    # Either pick an item from the list (item_id) or describe another one
    # (other_item_name + other_item_unit) when it is not in the list yet.
    item_id: Optional[int] = None
    other_item_name: Optional[str] = Field(default=None, max_length=150)
    other_item_unit: Optional[str] = Field(default=None, max_length=50)
    packaging: str = Field(min_length=1, max_length=100)
    quantity: int = Field(gt=0)
    estimated_value: Optional[Decimal] = Field(default=None, ge=0)

    @model_validator(mode="after")
    def check_item_given(self):
        if self.item_id is None and not (self.other_item_name or "").strip():
            raise ValueError("Choose an item, or enter the name of another item")
        return self


class _PickupFields(BaseModel):
    """Handover method and, for Door to Door, the pickup location
    (UC-D2 alt 7b / 7c)."""

    handover_method: HandoverMethod
    pickup_address: Optional[str] = None
    pickup_lat: Optional[float] = Field(default=None, ge=-90, le=90)
    pickup_lng: Optional[float] = Field(default=None, ge=-180, le=180)
    pickup_landmark: Optional[str] = Field(default=None, max_length=300)

    @model_validator(mode="after")
    def check_pickup(self):
        if self.handover_method == "Door to Door":
            if not (self.pickup_address or "").strip():
                raise ValueError("pickup_address is required when handover_method is 'Door to Door'")
            if (self.pickup_lat is None) != (self.pickup_lng is None):
                raise ValueError("Send both pickup_lat and pickup_lng, or neither")
            self.pickup_address = self.pickup_address.strip()
            if self.pickup_landmark is not None:
                self.pickup_landmark = self.pickup_landmark.strip() or None
        else:
            # Drop Off: the donor brings the goods to CSWS, nothing to pick up.
            self.pickup_address = None
            self.pickup_lat = None
            self.pickup_lng = None
            self.pickup_landmark = None
        return self


class PhysicalDonationCreate(_ItemFields, _PickupFields):
    """Single-item donation (POST /donations/). Kept for older clients and
    tests; the app uses DonationBatchCreate."""

    report_id: int
    guest_donor: Optional[GuestDonorInfo] = None  # Only present for non-logged-in donors


class DonationLine(_ItemFields):
    pass


class DonationBatchCreate(_PickupFields):
    """One donation with one or more items -> one QR reference
    (POST /donations/batch)."""

    report_id: int
    items: List[DonationLine] = Field(min_length=1, max_length=30)
    guest_donor: Optional[GuestDonorInfo] = None  # Only present for non-logged-in donors


class PhysicalDonationResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    donation_id: int
    user_id: Optional[int]
    guest_donor_id: Optional[int]
    report_id: int
    item_id: int
    packaging: str
    quantity: int
    estimated_value: Optional[Decimal]
    handover_method: str
    pickup_address: Optional[str]
    pickup_lat: Optional[float] = None
    pickup_lng: Optional[float] = None
    pickup_landmark: Optional[str] = None
    qr_reference: str
    batch_reference: Optional[str] = None
    status: str
    created_at: datetime