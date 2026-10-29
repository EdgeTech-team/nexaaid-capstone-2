from datetime import datetime
from typing import Optional
from pydantic import ConfigDict
from pydantic import BaseModel


class ReceivedGoodsCreate(BaseModel):
    donation_id: int
    actual_quantity: int   # in the item's base unit (kg, L, pcs...)
    notes: Optional[str] = None
    # Per-item fulfillment (Oct 2026): what the goods really are, when the
    # donor's item was wrong or typed in ("Bigas" -> Rice). Optional.
    item_id: Optional[int] = None


class ReceivedGoodsResponse(BaseModel):
    receive_id: int
    donation_id: int
    actual_quantity: int
    received_by_user_id: int
    received_at: datetime
    notes: Optional[str]

    model_config = ConfigDict(from_attributes=True)
