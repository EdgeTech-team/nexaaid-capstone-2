from datetime import datetime
from decimal import Decimal
from typing import Optional, Literal
from pydantic import BaseModel, Field, model_validator


class GuestDonorInfo(BaseModel):
    full_name: str
    contact_number: str
    email: Optional[str] = None
    
class PhysicalDonationCreate(BaseModel):
    report_id : int
    # Either pick an item from the list (item_id) or describe another one
    # (other_item_name + other_item_unit) when it is not in the list yet.
    item_id: Optional[int] = None
    other_item_name: Optional[str] = Field(default=None, max_length=150)
    other_item_unit: Optional[str] = Field(default=None, max_length=50)
    packaging : str
    quantity : int
    estimated_value : Optional[Decimal] = None
    handover_method: Literal["Drop Off", "Door to Door"]
    pickup_address: Optional[str] = None
    guest_donor: Optional[GuestDonorInfo] = None #Only Present for Non logged in donors
    
    @model_validator(mode="after")
    def check_item_given(self):
        if self.item_id is None and not (self.other_item_name or "").strip():
            raise ValueError("Choose an item, or enter the name of another item")
        return self

    @model_validator(mode="after")
    def check_pickup_address_required(self):
            if self.handover_method == "Door to Door" and not self.pickup_address:
                raise ValueError("pickup_address is required when handover_method is 'Door to Door'")
            return self
    
    
class PhysicalDonationResponse(BaseModel):
        donation_id: int
        user_id: Optional[int]
        guest_donor_id: Optional[int]
        report_id: int
        item_id: int
        packaging : str
        quantity : int
        estimated_value : Optional[Decimal] 
        handover_method: str
        pickup_address: Optional[str] 
        qr_reference: str
        status: str
        created_at: datetime
        
        class Config:
            from_attributes = True