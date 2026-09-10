# schemas/user_schema.py
from pydantic import BaseModel, EmailStr, Field
from typing import Optional

class DonorRegisterRequest(BaseModel):
    first_name: str = Field(..., min_length=1, max_length=50)
    last_name: str = Field(..., min_length=1, max_length=50)
    email: EmailStr = Field(..., max_length=150)
    password: str = Field(..., min_length=8, max_length=128)
    contact_number: str = Field(..., min_length=7, max_length=20)

class UserResponse(BaseModel):
    user_id: int
    first_name: str
    last_name: str
    email: str
    role_id: int
    is_active: bool

    class Config:
        from_attributes = True

INTERNAL_ROLES = {
    "CSWS Disaster Unit", "CSWS Main Office", "CMO Representative",
    "DRRMO Logistics Support", "Barangay Receiving Representative",
}

class InternalAccountCreateRequest(BaseModel):
    first_name: str = Field(..., min_length=1, max_length=50)
    last_name: str = Field(..., min_length=1, max_length=50)
    email: EmailStr = Field(..., max_length=150)
    password: str = Field(..., min_length=8, max_length=128)
    contact_number: str = Field(..., min_length=7, max_length=20)
    role_name: str
    assigned_barangay_id: Optional[int] = None