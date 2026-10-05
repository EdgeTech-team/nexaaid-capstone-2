from datetime import datetime
from typing import Literal, Optional

from pydantic import BaseModel, Field


def _count(n: int, word: str) -> str:
    return f"{n} {word}" if n == 1 else f"{n} {word}s"


class SubmitLogisticsRequest(BaseModel):
    """CSWS Main Office asks DRRMO for transport (UC-CM2 alt 3a).
    I4: CSWS picks how many trucks, drivers and volunteers; no typing."""
    delivery_id: int
    trucks: int = Field(..., ge=1, le=10)
    drivers: int = Field(..., ge=0, le=10)
    volunteers: int = Field(..., ge=0, le=20)

    def needs_text(self) -> str:
        parts = [_count(self.trucks, "truck")]
        if self.drivers:
            parts.append(_count(self.drivers, "driver"))
        if self.volunteers:
            parts.append(_count(self.volunteers, "volunteer"))
        return "Needs " + ", ".join(parts)


class AcceptLogisticsRequest(BaseModel):
    """DRRMO just accepts. No schedule (I4)."""
    notes: Optional[str] = Field(default=None, max_length=1000)


class DeclineLogisticsRequest(BaseModel):
    """DRRMO uses this to decline."""
    notes: str = Field(..., min_length=1, max_length=1000)  # reason required when declining


class LogisticsRequestResponse(BaseModel):
    request_id: int
    delivery_id: int
    requested_by_user_id: int
    assigned_to_user_id: Optional[int]
    status: Literal["Pending", "Accepted", "Declined", "Completed"]
    scheduled_date: Optional[datetime]
    notes: Optional[str]
    created_at: datetime

    class Config:
        from_attributes = True