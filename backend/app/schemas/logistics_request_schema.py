from pydantic import BaseModel, Field
from typing import Optional, Literal
from datetime import datetime


class SubmitLogisticsRequest(BaseModel):
    """CSWS submits this for a delivery it is preparing, when it needs
    DRRMO transport (manuscript UC-CM2 alt flow 3a)."""
    delivery_id: int
    notes: Optional[str] = Field(default=None, max_length=1000)


class AcceptLogisticsRequest(BaseModel):
    """DRRMO uses this to accept and schedule."""
    scheduled_date: datetime
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