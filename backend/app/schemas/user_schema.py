# schemas/user_schema.py
from typing import Optional
from pydantic import BaseModel, EmailStr, Field, field_validator, model_validator

from core.validators import (
    clean_person_name, clean_email, clean_ph_mobile, clean_employee_id, clean_url,
)
from core.passwords import validate_password_strength
from datetime import datetime

class DonorRegisterRequest(BaseModel):
    # Donors choose their own password (staff get an emailed temporary one instead).
    first_name: str
    last_name: str
    email: EmailStr
    contact_number: str
    password: str = Field(..., min_length=8, max_length=64)
    confirm_password: str = Field(..., min_length=1, max_length=64)
    id_document_url: Optional[str] = None  # manuscript 1.2 (valid ID), link until uploads exist

    @field_validator("first_name")
    @classmethod
    def _fn(cls, v): return clean_person_name(v, "First name")

    @field_validator("last_name")
    @classmethod
    def _ln(cls, v): return clean_person_name(v, "Last name")

    @field_validator("email")
    @classmethod
    def _em(cls, v): return clean_email(str(v))

    @field_validator("contact_number")
    @classmethod
    def _cn(cls, v): return clean_ph_mobile(v)

    @field_validator("id_document_url")
    @classmethod
    def _url(cls, v): return clean_url(v)

    @model_validator(mode="after")
    def _check_password(self):
        if self.password != self.confirm_password:
            raise ValueError("Passwords do not match")
        validate_password_strength(
            self.password, email=self.email, names=(self.first_name, self.last_name)
        )
        return self


class UserResponse(BaseModel):
    user_id: int
    first_name: str
    last_name: str
    email: str
    role_id: int
    is_active: bool
    employee_id: Optional[str] = None
    must_change_password: bool = False

    class Config:
        from_attributes = True


INTERNAL_ROLES = {
    "CSWS Disaster Unit", "CSWS Main Office", "CMO Representative",
    "DRRMO Logistics Support", "Barangay Receiving Representative",
}


class InternalAccountCreateRequest(BaseModel):
    # Staff: no password field. Auto-generated + emailed. employee_id is REQUIRED.
    first_name: str
    last_name: str
    email: EmailStr
    contact_number: str
    employee_id: str
    role_name: str
    assigned_barangay_id: Optional[int] = Field(default=None, gt=0)

    @field_validator("first_name")
    @classmethod
    def _fn(cls, v): return clean_person_name(v, "First name")

    @field_validator("last_name")
    @classmethod
    def _ln(cls, v): return clean_person_name(v, "Last name")

    @field_validator("email")
    @classmethod
    def _em(cls, v): return clean_email(str(v))

    @field_validator("contact_number")
    @classmethod
    def _cn(cls, v): return clean_ph_mobile(v)

    @field_validator("employee_id")
    @classmethod
    def _emp(cls, v): return clean_employee_id(v)


class LoginRequest(BaseModel):
    email: EmailStr
    password: str = Field(..., min_length=1, max_length=128)  # no strength rules on login


class ChangePasswordRequest(BaseModel):
    current_password: str = Field(..., min_length=1, max_length=128)
    new_password: str = Field(..., min_length=8, max_length=64)
    confirm_new_password: str = Field(..., min_length=8, max_length=64)

    @field_validator("confirm_new_password")
    @classmethod
    def _match(cls, v, info):
        if "new_password" in info.data and v != info.data["new_password"]:
            raise ValueError("Passwords do not match")
        return v


class AdminUserResponse(BaseModel):
    user_id: int
    first_name: str
    last_name: str
    email: str
    role_id: int
    role_name: str
    assigned_barangay_id: Optional[int] = None
    employee_id: Optional[str] = None
    is_active: bool
    created_at: datetime