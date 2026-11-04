"""
app/schemas/report.py

Pydantic schemas for Module 3.4 — Report Management.

Split by intent, not just by model:
- Create: what a REPORTER submits (Web/Mobile). user_id is NOT here —
  it comes from the authenticated user, set server-side.
- Update: what CSWS/staff can change after intake (status, priority,
  AI fields). Reporters should not be able to touch these.
- Response: full row, safe to return to any authorized reader.
- Sms* : the SMS ingestion path, which creates a report + its metadata
  together in one call.

CHANGE LOG
- Concerns2.txt 2.1 (Castillo): affected_families and estimated_quantity
  now only accept whole numbers within realistic limits. Text like
  "dwadawdas" or decimals is rejected with a 422, and 0 / negative values
  are rejected. Limits are the constants below so they are easy to adjust.
  Input-only: existing rows and all response schemas are unchanged.
"""

from datetime import datetime
from decimal import Decimal
from typing import Annotated, List, Optional, Literal

from pydantic import AfterValidator, BaseModel, ConfigDict, Field, field_validator, model_validator

from core.validators import clean_text
from models.report import canonical_source

# Stored exactly as the live DB constraint expects; any casing is accepted
# on input ("web", "WEB", ...) and normalised.
SourceType = Literal["Web", "Mobile", "SMS"]

# ---------------------------------------------------------------------------
# Input limits (Concerns2.txt 2.1)
# The largest Cebu City barangays have roughly 15,000-17,000 households, so
# 20,000 families covers any single-barangay report with room to spare.
# Confirm both numbers with CSWS / your adviser; change them here only.
# ---------------------------------------------------------------------------
MAX_AFFECTED_FAMILIES = 20_000
# Testing (Oct 28): no business limit on how much a report may need, per
# item or in total. Only the database's whole-number range is kept: one
# need up to 9 digits, the total within a PostgreSQL integer.
MAX_ESTIMATED_QUANTITY = 999_999_999
MAX_TOTAL_QUANTITY = 2_147_483_647

# Accepts 12 or "12" (in case the app sends the text field as a string),
# rejects letters ("dwadawdas") and decimals (12.5).
AffectedFamilies = Optional[int]
EstimatedQuantity = Optional[int]


def _clean_type_other(v):
    return None if v is None or not v.strip() else clean_text(v, "Kind of disaster", 2, 100)


# What kind of disaster, when the type is "Other" (e.g. "Gas leak"); blank =
# none. The route requires it for Other and clears it for every other type.
DisasterTypeOther = Annotated[Optional[str], AfterValidator(_clean_type_other)]


def _families_field():
    return Field(
        default=None,
        ge=1,
        le=MAX_AFFECTED_FAMILIES,
        description=f"Whole number from 1 to {MAX_AFFECTED_FAMILIES:,}",
    )


def _quantity_field():
    """estimated_quantity: the total of all needs (or one "General needs"
    number from older apps and SMS)."""
    return Field(
        default=None,
        ge=1,
        le=MAX_TOTAL_QUANTITY,
        description=f"Whole number from 1 to {MAX_TOTAL_QUANTITY:,}",
    )


# ---------------------------------------------------------------------------
# DisasterReport schemas
# ---------------------------------------------------------------------------

class ReportNeedIn(BaseModel):
    """One need of a report (per-item fulfillment, Oct 2026): an item from
    the list, or "something else" (name + unit), and how much is needed in
    that item's base unit (kg, L, pcs...)."""
    item_id: Optional[int] = None
    other_item_name: Optional[str] = Field(default=None, max_length=150)
    other_item_unit: Optional[str] = Field(default=None, max_length=50)
    quantity: int = Field(ge=1, le=MAX_ESTIMATED_QUANTITY)


class ReportNeedOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    need_id: int
    item_id: Optional[int]          # None = "General needs" (older report)
    item_name: str
    unit: Optional[str]
    quantity: int


# needs: newer apps send one line per item. When it is missing (older apps,
# SMS), estimated_quantity becomes a single "General needs" line, as before.
NeedsField = Optional[List[ReportNeedIn]]


class DisasterReportCreate(BaseModel):
    disaster_type_id: int
    disaster_type_other: DisasterTypeOther = None
    barangay_id: int
    sitio_id: Optional[int] = None
    # Several sitios of the barangay (problema_napud 2.2). When given, it
    # wins over sitio_id; empty = the whole barangay.
    sitio_ids: Optional[List[int]] = None
    description: Optional[str] = None
    affected_families: AffectedFamilies = _families_field()
    assistance_needed: Optional[str] = None
    estimated_quantity: EstimatedQuantity = _quantity_field()
    needs: NeedsField = Field(default=None, max_length=30)
    source: SourceType = "Web"

    @field_validator("source", mode="before")
    @classmethod
    def _canonical_source(cls, v):
        return canonical_source(v)


class DisasterReportEdit(BaseModel):
    """The reporter (CSWS Disaster Unit) corrects their own report before the
    Administrator validates it (Oct 11 notes). Same fields as a new report;
    the source stays as it was."""
    disaster_type_id: int
    disaster_type_other: DisasterTypeOther = None
    barangay_id: int
    sitio_id: Optional[int] = None
    # Several sitios of the barangay (problema_napud 2.2). When given, it
    # wins over sitio_id; empty = the whole barangay.
    sitio_ids: Optional[List[int]] = None
    description: Optional[str] = None
    affected_families: AffectedFamilies = _families_field()
    assistance_needed: Optional[str] = None
    estimated_quantity: EstimatedQuantity = _quantity_field()
    needs: NeedsField = Field(default=None, max_length=30)


class ReportWithdraw(BaseModel):
    reason: Optional[str] = Field(default=None, max_length=300)


class DisasterReportUpdate(BaseModel):
    """Administrator corrections. All optional (PATCH semantics).

    F-07: the status is NOT set here. Validate, Reject (Administrator) and
    Withdraw (the reporter) change it, each with its own checks, records and
    notices."""

    description: Optional[str] = None
    affected_families: AffectedFamilies = _families_field()
    assistance_needed: Optional[str] = None
    estimated_quantity: EstimatedQuantity = _quantity_field()
    needs: NeedsField = Field(default=None, max_length=30)

    # Testing #5 (Oct 2026): priority is always computed by the system
    # (manuscript Table 32: "automated but non-autonomous"; people decide
    # the actual relief allocation). It can no longer be set by hand here:
    # the next delivery receipt silently overwrote it anyway.
    @model_validator(mode="before")
    @classmethod
    def _no_manual_priority(cls, data):
        if isinstance(data, dict):
            sent = {"priority_level", "ai_priority_score", "ai_recommendation"} & set(data)
            if sent:
                raise ValueError(
                    "Priority is computed by the system and cannot be set by hand "
                    f"({', '.join(sorted(sent))})."
                )
            
            if "status" in data:
                raise ValueError(
                    "The report's status cannot be changed here. Use Validate or Reject "
                    "(Administrator) or Withdraw (the reporter)."
                )

        return data


class DisasterReportResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    report_id: int
    user_id: int
    disaster_type_id: int
    disaster_type_other: Optional[str] = None
    barangay_id: int
    sitio_id: Optional[int]
    sitio_ids: List[int] = []
    sitio_names: List[str] = []
    description: Optional[str]
    affected_families: Optional[int]
    assistance_needed: Optional[str]
    estimated_quantity: Optional[int]
    source: SourceType
    ai_priority_score: Optional[Decimal]
    ai_recommendation: Optional[str]
    priority_level: Optional[str]
    status: str
    ai_processed_at: Optional[datetime]
    validated_by: Optional[int]
    rejection_reason: Optional[str]
    created_at: datetime
    updated_at: datetime
    disaster_type_name: Optional[str] = None
    barangay_name: Optional[str] = None
    priority_guidance: Optional[str] = None
    needs: List[ReportNeedOut] = []

    @field_validator("source", mode="before")
    @classmethod
    def _canonical_source(cls, v):
        return canonical_source(v)


# ---------------------------------------------------------------------------
# Admin validation actions — UC-02 steps 5/6, extension 5a
# ---------------------------------------------------------------------------

class ReportValidate(BaseModel):
    """Body for approving a report. Nothing required — validated_by and
    status are set server-side from the authenticated admin."""
    pass


class ReportReject(BaseModel):
    """Body for rejecting a report. Reason is required so the reporting
    Barangay Representative gets specific feedback to correct (UC-02 5a)."""
    rejection_reason: str = Field(min_length=1)


# ---------------------------------------------------------------------------
# SMS ingestion — creates a DisasterReport (source='SMS') + its metadata
# ---------------------------------------------------------------------------

class SmsReportIngest(BaseModel):
    """
    Submitted by whoever encodes an incoming SMS report (staff, not the
    original texter). encoded_by_user_id comes from the authenticated
    user, not the client.
    """
    contact_number: str = Field(max_length=20)
    raw_message: str

    disaster_type_id: int
    disaster_type_other: DisasterTypeOther = None
    barangay_id: int
    sitio_id: Optional[int] = None
    sitio_ids: Optional[List[int]] = None
    description: Optional[str] = None
    affected_families: AffectedFamilies = _families_field()
    assistance_needed: Optional[str] = None
    estimated_quantity: EstimatedQuantity = _quantity_field()
    needs: NeedsField = Field(default=None, max_length=30)


class SmsReportMetadataResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    sms_meta_id: int
    report_id: int
    contact_number: str
    raw_message: str
    encoded_by_user_id: int
    encoded_at: datetime


class SmsReportIngestResponse(BaseModel):
    report: DisasterReportResponse
    sms_metadata: SmsReportMetadataResponse


class ReportMonitoringResponse(DisasterReportResponse):
    fulfillment_status: Optional[str] = None
    fulfillment_percentage: Optional[Decimal] = None
    total_items_needed: Optional[int] = None
    total_items_delivered: Optional[int] = None