# schemas/donation_confirmation_schema.py
from pydantic import BaseModel, Field, model_validator
from typing import Optional
from pydantic import ConfigDict

class ConfirmDonationRequest(BaseModel):
    # Oct 11 notes: the CMO "acknowledges" (the app's word); "Acknowledged"
    # is accepted and stored as the existing status "Confirmed".
    status: str = Field(..., pattern="^(Confirmed|Acknowledged|On Hold|Pending Review)$")
    notes: Optional[str] = Field(default=None, max_length=200)

    @model_validator(mode="after")
    def hold_needs_reason(self):
        if self.status == "Acknowledged":
            self.status = "Confirmed"
        # "   " counts as empty
        if self.notes is not None:
            self.notes = self.notes.strip() or None
        if self.status == "On Hold" and not self.notes:
            raise ValueError("A reason is required when putting a donation on hold")
        return self


class DonationConfirmationResponse(BaseModel):
    confirmation_id: int
    donation_id: int
    status: str
    notes: Optional[str]

    model_config = ConfigDict(from_attributes=True)
