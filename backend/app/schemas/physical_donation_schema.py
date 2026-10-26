import os
import re
from datetime import date, datetime, timedelta, timezone
from decimal import Decimal
from typing import List, Literal, Optional

from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator
from pydantic import EmailStr

from core.validators import clean_email, clean_person_name


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


def pickup_rules_view() -> dict:
    """pickup_rules() plus the service areas, for GET /donations/pickup-rules."""
    return {
        **pickup_rules(),
        "service_areas": [
            {"name": a["name"], "aliases": a["aliases"], "barangays": a["barangays"]}
            for a in pickup_service_areas()
        ],
        "service_areas_label": service_areas_label(),
    }


def _env_float(name: str, default: float) -> float:
    try:
        return float(os.getenv(name, default))
    except ValueError:
        return default


def pickup_area() -> dict:
    """Where Door to Door pickups can happen (Oct 11 notes: the map stays
    inside Cebu province, and pickups far from the CSWS office can be
    declined). Set in .env:
        PICKUP_AREA_BBOX=minLon,minLat,maxLon,maxLat   (default: Cebu province;
                                                       a Mandaue-only box also works)
        PICKUP_AREA_NAME=Cebu province
        PICKUP_MAX_KM=20       farther than this from the office is flagged "far"
    The office is DROPOFF_LAT / DROPOFF_LNG, or Mandaue City centre."""
    raw = os.getenv("PICKUP_AREA_BBOX", "123.25,9.40,124.10,11.30")
    try:
        min_lng, min_lat, max_lng, max_lat = (float(x) for x in raw.split(","))
    except ValueError:
        min_lng, min_lat, max_lng, max_lat = 123.25, 9.40, 124.10, 11.30
    office_lat = os.getenv("DROPOFF_LAT")
    office_lng = os.getenv("DROPOFF_LNG")
    try:
        office = (float(office_lat), float(office_lng)) if office_lat and office_lng else None
    except ValueError:
        office = None
    return {
        "name": os.getenv("PICKUP_AREA_NAME", "Cebu province"),
        "bbox": [min_lng, min_lat, max_lng, max_lat],
        "office": office or (10.3300, 123.9300),  # Mandaue City centre
        "max_km": _env_float("PICKUP_MAX_KM", 20),
    }


def inside_pickup_area(lat: float, lng: float) -> bool:
    min_lng, min_lat, max_lng, max_lat = pickup_area()["bbox"]
    return min_lat <= lat <= max_lat and min_lng <= lng <= max_lng


def km_from_office(lat, lng) -> Optional[float]:
    """Straight-line distance from the CSWS office, in km (None without a pin)."""
    if lat is None or lng is None:
        return None
    import math
    o_lat, o_lng = pickup_area()["office"]
    p1, p2 = math.radians(o_lat), math.radians(float(lat))
    dp, dl = p2 - p1, math.radians(float(lng) - o_lng)
    a = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return round(6371 * 2 * math.asin(math.sqrt(a)), 1)


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


def check_pickup_dates(values) -> List[date]:
    """The specific dates a donor is home for a Door to Door pickup (calendar
    picker). Raises ValueError (shown to the donor) if none is chosen, a date
    is in the past, too far ahead, or not a CSWS pickup day."""
    rules = pickup_rules()
    today = datetime.now(MANILA).date()
    dates = sorted(set(values or []))
    if not dates:
        raise ValueError("Choose at least one date CSWS can pick up your donation")
    if dates[0] < today:
        raise ValueError("Pickup dates must be today or later")
    if dates[-1] > today + timedelta(days=rules["max_days_ahead"]):
        raise ValueError(f"Choose pickup dates within {rules['max_days_ahead']} days")
    off = [d for d in dates if d.isoweekday() not in rules["days"]]
    if off:
        names = ", ".join(_date_short(d) for d in off)
        raise ValueError(f"CSWS does not pick up on {names}. Pickups: {rules['label']}")
    return dates


def _date_short(d: date) -> str:
    """date(2026, 10, 26) -> "Mon, Oct 26"."""
    return f"{_DAY_SHORT[d.isoweekday() - 1]}, {d.strftime('%b')} {d.day}"


def encode_pickup_dates(dates) -> Optional[str]:
    """[date(2026, 10, 26), ...] -> "2026-10-26,..." (physical_donations.pickup_dates)."""
    return ",".join(d.isoformat() for d in sorted(set(dates))) if dates else None


def decode_pickup_dates(raw) -> List[date]:
    """"2026-10-26,2026-10-28" -> [date, date]. Also accepts a list. Bad parts are skipped."""
    if not raw:
        return []
    parts = raw if isinstance(raw, (list, tuple)) else str(raw).split(",")
    out = set()
    for p in parts:
        if isinstance(p, date):
            out.add(p)
            continue
        try:
            out.add(date.fromisoformat(str(p).strip()))
        except ValueError:
            continue
    return sorted(out)


def pickup_dates_label(raw) -> Optional[str]:
    """"2026-10-26,2026-10-28" -> "Mon, Oct 26 · Wed, Oct 28"."""
    dates = decode_pickup_dates(raw)
    return " · ".join(_date_short(d) for d in dates) if dates else None


# Door to Door service areas (CSWS, Oct 2026). A pickup address or landmark
# must name one of these places. Cebu City is only its northern barangays near
# Mandaue. Override in .env without code, e.g.
#   PICKUP_SERVICE_AREAS="Mandaue;Consolacion;Lapu-Lapu|Lapulapu|Mactan;Cebu City:Banilad,Talamban"
# (";" between areas, "|" between other names of the same place,
#  ":" then the allowed barangays when only some of the city is served).
_DEFAULT_SERVICE_AREAS = (
    "Mandaue;"
    "Cebu City:Banilad,Talamban,Bacayan,Pit-os,Apas,Kasambagan,Lahug,Mabolo;"
    "Consolacion;"
    "Lapu-Lapu|Lapulapu|Mactan"
)


def _squash(text: str) -> str:
    """Lowercase letters and digits only: "Lapu-Lapu City" -> "lapulapucity"."""
    return re.sub(r"[^a-z0-9]", "", (text or "").lower())


def pickup_service_areas() -> List[dict]:
    """[{"name": "Mandaue", "aliases": [...], "barangays": [] = all}, ...]."""
    raw = os.getenv("PICKUP_SERVICE_AREAS") or _DEFAULT_SERVICE_AREAS
    areas = []
    for part in raw.split(";"):
        names, _, brgys = part.partition(":")
        aliases = [n.strip() for n in names.split("|") if n.strip()]
        if not aliases:
            continue
        areas.append({
            "name": aliases[0],
            "aliases": aliases,
            "barangays": [b.strip() for b in brgys.split(",") if b.strip()],
        })
    return areas


def in_service_area(*texts: Optional[str]) -> bool:
    """True when the address / landmark text names a served place (and, for
    a partly served city, one of its served barangays)."""
    text = _squash(" ".join(t for t in texts if t))
    if not text:
        return False
    for area in pickup_service_areas():
        if not any(_squash(a) in text for a in area["aliases"]):
            continue
        if not area["barangays"] or any(_squash(b) in text for b in area["barangays"]):
            return True
    return False


def place_in(text: Optional[str]) -> Optional[str]:
    """Best guess of the town in an OpenStreetMap address, for messages:
    "Carcar Diversion Road, Dapdap, Carcar, Cebu" -> "Carcar"."""
    parts = [p.strip() for p in (text or "").split(",") if p.strip()]
    while len(parts) >= 2 and _squash(parts[-1]) in ("cebu", "philippines", "centralvisayas"):
        parts = parts[:-1]
    return parts[-1] if parts else None


def service_areas_label() -> str:
    """"Mandaue, Cebu City (Banilad, Talamban, ...), Consolacion, Lapu-Lapu"."""
    parts = []
    for a in pickup_service_areas():
        parts.append(f"{a['name']} ({', '.join(a['barangays'])})" if a["barangays"] else a["name"])
    return ", ".join(parts)


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


# Testing fix 4.1: the quantity unit says how much (kg, pcs, gallons...). A
# sack is packaging, which already has its own field, so it is not a unit.
# Same list as mobile/lib/ui/quantity_units.dart.
# Base units (per-item fulfillment): weight is kg, volume is L; grams, ml
# and gallons are given as the size of each (services/units.py).
QUANTITY_UNITS = (
    "kg", "L", "pcs", "packs", "cans", "bottles", "boxes", "kits", "sets", "pairs",
)
_PACKAGING_WORDS = {"sack", "sacks"}


def clean_quantity_unit(value: Optional[str]) -> Optional[str]:
    """None/blank -> None. Rejects packaging words; matches the list
    case-insensitively so "KG" is stored as "kg"."""
    unit = (value or "").strip()
    if not unit:
        return None
    if unit.lower() in _PACKAGING_WORDS:
        raise ValueError(
            "A sack is packaging, not a quantity unit. Choose the packaging "
            "in the Packaging field and a unit like kg or pcs here.")
    for u in QUANTITY_UNITS:
        if u.lower() == unit.lower():
            return u
    raise ValueError(f"Unit must be one of: {', '.join(QUANTITY_UNITS)}")


class GuestDonorInfo(BaseModel):
    """A guest donor: no account (UC-D2 preconditions). F-09: checked with
    the same rules as a registration, and the guest must agree to the
    processing of this data (RA 10173). The API refuses it otherwise, so the
    app's checkbox is never the only check."""
    full_name: str
    contact_number: str
    email: Optional[EmailStr] = None
    consent: bool        # required: name, contact number and pickup address

    @field_validator("full_name")
    @classmethod
    def _name(cls, v):
        return clean_person_name(v, "Full name", 2, 100)

    @field_validator("contact_number")
    @classmethod
    def _phone(cls, v):
        return normalize_ph_mobile(v)   # both endpoints now, not only /donations/batch

    @field_validator("email", mode="before")
    @classmethod
    def _blank_email(cls, v):
        return None if isinstance(v, str) and not v.strip() else v

    @field_validator("email")
    @classmethod
    def _email(cls, v):
        return None if v is None else clean_email(str(v))

    @field_validator("consent")
    @classmethod
    def _consent(cls, v):
        if v is not True:
            raise ValueError("You must agree to the processing of your personal data (RA 10173)")
        return v


class _ItemFields(BaseModel):
    """What one item line carries (UC-D2 step 6: item type, packaging size,
    quantity, estimated value)."""

    # Either pick an item from the list (item_id) or describe another one
    # (other_item_name + other_item_unit) when it is not in the list yet.
    item_id: Optional[int] = None
    other_item_name: Optional[str] = Field(default=None, max_length=150)
    other_item_unit: Optional[str] = Field(default=None, max_length=50)
    # Older apps: the total in the item's base unit + a packaging label.
    packaging: Optional[str] = Field(default=None, max_length=100)
    quantity: Optional[int] = Field(default=None, gt=0)
    # Newer apps (per-item fulfillment, Oct 2026): describe it instead and
    # the server works out the total in the base unit (services/units.py):
    #   pack_count x per_pack x size   e.g. 3 boxes x 16 x 1.5 L = 72 L
    # size = one of the item's sizes (size_id, from /lookups), or a custom
    # size_amount + size_unit (kg/g for weight, L/ml/gallon for volume),
    # or nothing (= 1 base unit, e.g. 1 can).
    pack_count: Optional[int] = Field(default=None, gt=0, le=100_000)
    per_pack: Optional[int] = Field(default=None, gt=0, le=10_000)
    size_id: Optional[int] = None
    size_amount: Optional[Decimal] = Field(default=None, gt=0, le=100_000)
    size_unit: Optional[str] = Field(default=None, max_length=20)
    estimated_value: Optional[Decimal] = Field(default=None, ge=0)

    @field_validator("other_item_unit")
    @classmethod
    def _unit_not_packaging(cls, v: Optional[str]) -> Optional[str]:
        return clean_quantity_unit(v)   # testing fix 4.1

    @model_validator(mode="after")
    def check_item_given(self):
        if self.item_id is None and not (self.other_item_name or "").strip():
            raise ValueError("Choose an item, or enter the name of another item")
        if self.pack_count is None:
            if self.quantity is None:
                raise ValueError("Enter the quantity, or the number of packs")
            if not (self.packaging or "").strip():
                raise ValueError("Choose the packaging")
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
    # The app now sends specific dates (calendar picker); pickup_days is then
    # filled with their weekdays. Older clients may still send pickup_days.
    pickup_dates: Optional[List[date]] = Field(default=None, max_length=10)
    preferred_pickup_at: Optional[datetime] = None

    @model_validator(mode="after")
    def check_pickup(self):
        if self.handover_method == "Door to Door":
            if not (self.pickup_address or "").strip():
                raise ValueError("pickup_address is required when handover_method is 'Door to Door'")
            if (self.pickup_lat is None) != (self.pickup_lng is None):
                raise ValueError("Send both pickup_lat and pickup_lng, or neither")
            if self.pickup_lat is not None and not inside_pickup_area(self.pickup_lat, self.pickup_lng):
                raise ValueError(
                    f"Door to Door pickups are only within {pickup_area()['name']}. "
                    "Choose a landmark there, or choose Drop Off."
                )
            # Service areas (Mandaue, northern Cebu City, ...) are checked in
            # the routes (donation_routes._check_service_area): that needs the
            # map lookup of the pin, which a validator should not do.
            if self.pickup_dates:
                self.pickup_dates = check_pickup_dates(self.pickup_dates)
                self.pickup_days = sorted({d.isoweekday() for d in self.pickup_dates})
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
            self.pickup_dates = None
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


class DonationEntryEdit(_PickupFields):
    """The donor changes a donation that is still waiting (or was declined):
    items, handover method and pickup details (PUT /donations/entries/{ref}).
    Same rules as a new donation; the report and the QR stay the same."""

    items: List[DonationLine] = Field(min_length=1, max_length=30)

    @model_validator(mode="after")
    def check_pickup_time_given(self):
        if (self.handover_method == "Door to Door" and not self.pickup_days
                and self.preferred_pickup_at is None):
            raise ValueError("Choose at least one day CSWS can pick up your donation")
        return self


class DonationItemsAdd(BaseModel):
    """More items for a donation the donor already pledged (Oct 23): they
    join the same donation and QR as a new batch, with the same handover
    and pickup details (POST /donations/entries/{ref}/items)."""

    items: List[DonationLine] = Field(min_length=1, max_length=30)


class DonationItemRemove(BaseModel):
    """Why the donor removes an item (shown to CSWS and kept in the audit)."""

    reason: str = Field(min_length=3, max_length=200)

    @field_validator("reason")
    @classmethod
    def _reason_text(cls, v: str) -> str:
        v = v.strip()
        if len(v) < 3:
            raise ValueError("Say briefly why you are removing this item")
        return v


class PhysicalDonationResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    donation_id: int
    user_id: Optional[int]
    guest_donor_id: Optional[int]
    report_id: int
    item_id: int
    packaging: str
    quantity: int
    pack_count: Optional[int] = None
    per_pack: Optional[int] = None
    size_amount: Optional[Decimal] = None
    size_label: Optional[str] = None
    estimated_value: Optional[Decimal]
    handover_method: str
    pickup_address: Optional[str]
    pickup_lat: Optional[float] = None
    pickup_lng: Optional[float] = None
    pickup_landmark: Optional[str] = None
    pickup_notes: Optional[str] = None
    pickup_days: List[int] = []
    pickup_dates: List[date] = []
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

    @field_validator("pickup_dates", mode="before")
    @classmethod
    def _dates(cls, v):
        # Stored as "2026-10-26,2026-10-28" in physical_donations.pickup_dates.
        return decode_pickup_dates(v)