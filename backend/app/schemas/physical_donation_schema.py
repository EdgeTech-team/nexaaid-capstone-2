import os
import re
from datetime import datetime, timedelta, timezone
from decimal import Decimal
from typing import List, Literal, Optional

from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator

HandoverMethod = Literal["Drop Off", "Door to Door"]

# Philippine time (no daylight saving), used for pickup scheduling rules.
MANILA = timezone(timedelta(hours=8))
_DAY_NAMES = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
_DAY_SHORT = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]


def _env_int(name: str, default: int) -> int:
    try:
        return int(os.getenv(name, default))
    except ValueError:
        return default


def _hour_label(hour: int) -> str:
    suffix = "AM" if hour < 12 else "PM"
    return f"{(hour % 12) or 12}:00 {suffix}"


def pickup_rules() -> dict:
    """When CSWS does Door to Door pickups. Set in .env so CSWS can change
    them without new code. Days use 1 = Monday ... 7 = Sunday."""
    raw_days = os.getenv("PICKUP_DAYS", "1,2,3,4,5")
    days = sorted({int(d) for d in raw_days.split(",") if d.strip().isdigit() and 1 <= int(d) <= 7})
    days = days or [1, 2, 3, 4, 5]
    start = _env_int("PICKUP_START_HOUR", 9)
    end = _env_int("PICKUP_END_HOUR", 17)
    if days == list(range(days[0], days[-1] + 1)) and len(days) > 1:
        day_label = f"{_DAY_NAMES[days[0] - 1]} to {_DAY_NAMES[days[-1] - 1]}"
    else:
        day_label = ", ".join(_DAY_NAMES[d - 1] for d in days)
    return {
        "days": days,
        "start_hour": start,
        "end_hour": end,
        "min_lead_hours": _env_int("PICKUP_MIN_LEAD_HOURS", 1),
        "max_days_ahead": _env_int("PICKUP_MAX_DAYS_AHEAD", 30),
        "timezone": "Asia/Manila",
        "label": f"{day_label}, {_hour_label(start)} to {_hour_label(end)}",
        # The donor picks the days they are home (Mon / Tue / ...); this is
        # the note shown under the day buttons.
        "hours_label": f"{_hour_label(start)} to {_hour_label(end)}",
        "day_names": _DAY_SHORT,
    }


def check_pickup_days(values) -> List[int]:
    """The days a donor is available for a Door to Door pickup
    (1 = Monday ... 7 = Sunday). Raises ValueError (shown to the donor)
    if none is chosen or a day is not a CSWS pickup day."""
    rules = pickup_rules()
    days = sorted({int(d) for d in values or []})
    if not days:
        raise ValueError("Choose at least one day CSWS can pick up your donation")
    if any(d < 1 or d > 7 for d in days):
        raise ValueError("Pickup days use 1 = Monday ... 7 = Sunday")
    off = [d for d in days if d not in rules["days"]]
    if off:
        names = ", ".join(_DAY_NAMES[d - 1] for d in off)
        raise ValueError(f"CSWS does not pick up on {names}. Pickups: {rules['label']}")
    return days


def encode_pickup_days(days) -> Optional[str]:
    """[1, 3, 5] -> "1,3,5" (the physical_donations.pickup_days column)."""
    return ",".join(str(d) for d in days) if days else None


def decode_pickup_days(raw) -> List[int]:
    """"1,3,5" -> [1, 3, 5]. Also accepts a list. Bad parts are skipped."""
    if not raw:
        return []
    parts = raw if isinstance(raw, (list, tuple)) else str(raw).split(",")
    out = set()
    for p in parts:
        try:
            d = int(p)
        except (TypeError, ValueError):
            continue
        if 1 <= d <= 7:
            out.add(d)
    return sorted(out)


def pickup_days_label(raw) -> Optional[str]:
    """"1,3,5" -> "Mon, Wed, Fri"; every weekday -> "Mon to Fri"."""
    days = decode_pickup_days(raw)
    if not days:
        return None
    if len(days) > 2 and days == list(range(days[0], days[-1] + 1)):
        return f"{_DAY_SHORT[days[0] - 1]} to {_DAY_SHORT[days[-1] - 1]}"
    return ", ".join(_DAY_SHORT[d - 1] for d in days)


def check_preferred_pickup(value: datetime) -> datetime:
    """Raises ValueError (shown to the donor) if the time is not allowed."""
    if value.tzinfo is None:
        value = value.replace(tzinfo=timezone.utc)
    rules = pickup_rules()
    now = datetime.now(timezone.utc)
    if value < now + timedelta(hours=rules["min_lead_hours"]):
        raise ValueError(
            f"Preferred pickup must be at least {rules['min_lead_hours']} hour(s) from now"
        )
    if value > now + timedelta(days=rules["max_days_ahead"]):
        raise ValueError(
            f"Preferred pickup must be within {rules['max_days_ahead']} days"
        )
    local = value.astimezone(MANILA)
    if local.isoweekday() not in rules["days"]:
        raise ValueError(f"CSWS does pickups only on: {rules['label']}")
    minutes = local.hour * 60 + local.minute
    if not (rules["start_hour"] * 60 <= minutes <= rules["end_hour"] * 60):
        raise ValueError(f"Choose a pickup time within: {rules['label']}")
    # Stored as UTC so every database (and test SQLite) reads it back the same.
    return value.astimezone(timezone.utc)


_PH_MOBILE = re.compile(r"^(?:\+?63|0)9\d{9}$")


def normalize_ph_mobile(raw: str) -> str:
    """'0917 123 4567', '+63 917-123-4567', '639171234567' -> '09171234567'.
    Raises ValueError (shown to the donor) if it is not a PH mobile number."""
    digits = re.sub(r"[\s\-().]", "", raw or "")
    if not _PH_MOBILE.match(digits):
        raise ValueError("Enter a valid Philippine mobile number, e.g. 0917 123 4567")
    return "0" + digits[-10:]


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
    """Handover method and, for Door to Door, the pickup details
    (UC-D2 alt 7b / 7c)."""

    handover_method: HandoverMethod
    pickup_address: Optional[str] = None
    pickup_lat: Optional[float] = Field(default=None, ge=-90, le=90)
    pickup_lng: Optional[float] = Field(default=None, ge=-180, le=180)
    pickup_landmark: Optional[str] = Field(default=None, max_length=300)
    pickup_notes: Optional[str] = Field(default=None, max_length=300)
    # Days the donor is home for the pickup (1 = Monday ... 7 = Sunday).
    # Replaces preferred_pickup_at in the app; older clients may still send a
    # single date and time instead.
    pickup_days: Optional[List[int]] = Field(default=None, max_length=7)
    preferred_pickup_at: Optional[datetime] = None

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
            if self.pickup_notes is not None:
                self.pickup_notes = self.pickup_notes.strip() or None
            if self.pickup_days is not None:
                self.pickup_days = check_pickup_days(self.pickup_days)
            if self.preferred_pickup_at is not None:
                self.preferred_pickup_at = check_preferred_pickup(self.preferred_pickup_at)
        else:
            # Drop Off: the donor brings the goods to CSWS, nothing to pick up.
            self.pickup_address = None
            self.pickup_lat = None
            self.pickup_lng = None
            self.pickup_landmark = None
            self.pickup_notes = None
            self.pickup_days = None
            self.preferred_pickup_at = None
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
    (POST /donations/batch). Door to Door needs the donor's pickup days
    (or, from older clients, one preferred pickup time)."""

    report_id: int
    items: List[DonationLine] = Field(min_length=1, max_length=30)
    guest_donor: Optional[GuestDonorInfo] = None  # Only present for non-logged-in donors

    @model_validator(mode="after")
    def check_pickup_time_given(self):
        if (self.handover_method == "Door to Door" and not self.pickup_days
                and self.preferred_pickup_at is None):
            raise ValueError("Choose at least one day CSWS can pick up your donation")
        return self

    @model_validator(mode="after")
    def check_guest_phone(self):
        # CSWS must be able to call or text guests about their pickup.
        if self.guest_donor is not None:
            self.guest_donor.contact_number = normalize_ph_mobile(self.guest_donor.contact_number)
        return self


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
    pickup_notes: Optional[str] = None
    pickup_days: List[int] = []
    preferred_pickup_at: Optional[datetime] = None
    qr_reference: str
    batch_reference: Optional[str] = None
    status: str
    created_at: datetime
    @field_validator("pickup_days", mode="before")
    @classmethod
    def _days(cls, v):
        # Stored as "1,3,5" in physical_donations.pickup_days.
        return decode_pickup_days(v)
