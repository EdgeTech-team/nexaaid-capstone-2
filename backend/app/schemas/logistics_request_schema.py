from datetime import date, datetime, timedelta, timezone
from typing import List, Literal, Optional

from pydantic import BaseModel, Field, field_validator, model_validator
from pydantic import ConfigDict

def _count(n: int, word: str) -> str:
    return f"{n} {word}" if n == 1 else f"{n} {word}s"


class _Needs(BaseModel):
    """What CSWS asks DRRMO for. I4: pick numbers, no typing.
    Appendix H 7.1 (Oct 10 notes): no driver count, a truck comes with its
    driver. Manpower is the volunteers, and a pushcart is enough for small
    loads. Each one can be None (0), but at least one is needed."""
    trucks: int = Field(default=0, ge=0, le=10)
    volunteers: int = Field(default=0, ge=0, le=20)
    pushcarts: int = Field(default=0, ge=0, le=10)

    @model_validator(mode="after")
    def check_something_needed(self):
        if not (self.trucks or self.volunteers or self.pushcarts):
            raise ValueError("Choose at least one: a truck, volunteers or a pushcart")
        return self

    def needs_text(self) -> str:
        parts = []
        if self.trucks:
            parts.append(_count(self.trucks, "truck"))
        if self.volunteers:
            parts.append(_count(self.volunteers, "volunteer"))
        if self.pushcarts:
            parts.append(_count(self.pushcarts, "pushcart"))
        return "Needs " + ", ".join(parts)


# The same pickers when a delivery is created with "Needs DRRMO transport?".
TransportNeeds = _Needs


class SubmitLogisticsRequest(_Needs):
    """CSWS Main Office asks DRRMO for transport (UC-CM2 alt 3a)."""
    delivery_id: int


class SubmitPickupLogisticsRequest(_Needs):
    """The CSWS Disaster Unit asks DRRMO to help with a Door to Door pickup
    run it planned on the pickup map: one day, the donation entries (QR
    batch references) in the order the team will visit them."""
    pickup_date: date
    batch_references: List[str] = Field(..., min_length=1, max_length=40)
    notes: Optional[str] = Field(default=None, max_length=500)

    @model_validator(mode="after")
    def clean_refs(self):
        seen, refs = set(), []
        for raw in self.batch_references:
            ref = (raw or "").strip().upper()
            if ref and ref not in seen:
                seen.add(ref)
                refs.append(ref)
        if not refs:
            raise ValueError("Choose at least one Door to Door donation")
        self.batch_references = refs
        if self.notes is not None:
            self.notes = self.notes.strip() or None
        return self


# UC-DR1 step 5 / Table 36 alt 4a: a few minutes for the time spent in the
# accept dialog, so "now" still counts as a time to come.
SCHEDULE_GRACE = timedelta(minutes=5)


class AcceptLogisticsRequest(BaseModel):
    """UC-DR1 step 5 / Table 36 alt 4a (Nov 2026, replaces testing fix 7.4
    "DRRMO just accepts"): DRRMO accepts and says when its truck comes, with
    date and time pickers. Required for a delivery request (the endpoint
    answers 422 without it); a pickup run keeps its pickup day. Vehicle and
    driver are optional free text, kept in the request notes."""
    scheduled_date: Optional[datetime] = None
    vehicle: Optional[str] = Field(default=None, max_length=80)
    driver: Optional[str] = Field(default=None, max_length=80)
    notes: Optional[str] = Field(default=None, max_length=1000)

    @field_validator("vehicle", "driver", "notes")
    @classmethod
    def _blank_is_none(cls, v: Optional[str]) -> Optional[str]:
        return (v or "").strip() or None

    @field_validator("scheduled_date")
    @classmethod
    def _not_past(cls, v: Optional[datetime]) -> Optional[datetime]:
        if v is None:
            return None
        if v.tzinfo is None:          # stored times are UTC (services/donation_expiry.utc)
            v = v.replace(tzinfo=timezone.utc)
        if v < datetime.now(timezone.utc) - SCHEDULE_GRACE:
            raise ValueError("Pick a date and time that has not passed yet")
        return v


class DeclineLogisticsRequest(BaseModel):
    """DRRMO uses this to decline."""
    notes: str = Field(..., min_length=1, max_length=1000)  # reason required when declining


class LogisticsRequestResponse(BaseModel):
    request_id: int
    delivery_id: Optional[int]
    request_type: str = "Delivery"
    pickup_date: Optional[date] = None
    requested_by_user_id: int
    assigned_to_user_id: Optional[int]
    status: Literal["Pending", "Accepted", "Declined", "Completed", "Cancelled"]
    scheduled_date: Optional[datetime]
    notes: Optional[str]
    created_at: datetime

    model_config = ConfigDict(from_attributes=True)
