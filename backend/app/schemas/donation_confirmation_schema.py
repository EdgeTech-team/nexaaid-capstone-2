# schemas/donation_confirmation_schema.py
from pydantic import BaseModel, Field
from typing import Optional

class ConfirmDonationRequest(BaseModel):
    status: str = Field(..., pattern="^(Confirmed|On Hold|Pending Review)$")
    notes: Optional[str] = None

class DonationConfirmationResponse(BaseModel):
    confirmation_id: int
    donation_id: int
    status: str
    notes: Optional[str]

    class Config:
        from_attributes = True