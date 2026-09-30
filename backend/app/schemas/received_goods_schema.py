from datetime import datetime
from typing import Optional
from pydantic import BaseModel


class ReceivedGoodsCreate(BaseModel):
    donation_id: int
    actual_quantity: int
    notes: Optional[str] = None


class ReceivedGoodsResponse(BaseModel):
    receive_id: int
    donation_id: int
    actual_quantity: int
    received_by_user_id: int
    received_at: datetime
    notes: Optional[str]

    class Config:
        from_attributes = True