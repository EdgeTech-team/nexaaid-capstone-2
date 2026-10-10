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
from typing import Optional, Literal

from pydantic import BaseModel, ConfigDict, Field, field_validator

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
MAX_ESTIMATED_QUANTITY = 100_000

# Accepts 12 or "12" (in case the app sends the text field as a string),
# rejects letters ("dwadawdas") and decimals (12.5).
AffectedFamilies = Optional[int]
EstimatedQuantity = Optional[int]


def _families_field():
    return Field(
        default=None,
        ge=1,
        le=MAX_AFFECTED_FAMILIES,
        description=f"Whole number from 1 to {MAX_AFFECTED_FAMILIES:,}",
    )


def _quantity_field():
    return Field(
        default=None,
        ge=1,
        le=MAX_ESTIMATED_QUANTITY,
        description=f"Whole number from 1 to {MAX_ESTIMATED_QUANTITY:,}",
    )


# ---------------------------------------------------------------------------
# DisasterReport schemas
# ---------------------------------------------------------------------------

class DisasterReportCreate(BaseModel):
    disaster_type_id: int
    barangay_id: int
    sitio_id: Optional[int] = None
    description: Optional[str] = None
    affected_families: AffectedFamilies = _families_field()
    assistance_needed: Optional[str] = None
    estimated_quantity: EstimatedQuantity = _quantity_field()
    source: SourceType = "Web"

    @field_validator("source", mode="before")
    @classmethod
    def _canonical_source(cls, v):
        return canonical_source(v)


class DisasterReportUpdate(BaseModel):
    """Staff-only fields. All optional — PATCH semantics.

    For approving/rejecting a report specifically, use the dedicated
    /reports/{id}/validate and /reports/{id}/reject endpoints instead —
    those also set validated_by / rejection_reason correctly. Use
    `status` here only for other lifecycle transitions after validation
    (e.g. 'Dispatched', 'Resolved')."""
    status: Optional[str] = None
    priority_level: Optional[str] = None
    ai_priority_score: Optional[Decimal] = None
    ai_recommendation: Optional[str] = None
    description: Optional[str] = None
    affected_families: AffectedFamilies = _families_field()
    assistance_needed: Optional[str] = None
    estimated_quantity: EstimatedQuantity = _quantity_field()


class DisasterReportResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    report_id: int
    user_id: int
    disaster_type_id: int
    barangay_id: int
    sitio_id: Optional[int]
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
    barangay_id: int
    sitio_id: Optional[int] = None
    description: Optional[str] = None
    affected_families: AffectedFamilies = _families_field()
    assistance_needed: Optional[str] = None
    estimated_quantity: EstimatedQuantity = _quantity_field()


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