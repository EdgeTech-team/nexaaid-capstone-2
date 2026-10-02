# schemas/organization_schema.py
from typing import Optional
from pydantic import BaseModel, EmailStr, Field, field_validator, model_validator

from core.validators import (
    clean_person_name, clean_org_name, clean_email, clean_ph_mobile,
    clean_registration_no, clean_text, clean_url,
)
from core.passwords import validate_password_strength
from datetime import datetime
from typing import Optional


class OrganizationRegisterRequest(BaseModel):
    org_name: str
    organization_type: str
    address: str
    contact_person: str
    registration_no: str
    contact_email: EmailStr
    legitimacy_document_url: Optional[str] = None
    contact_number: str
    # Organizations choose their own password.
    password: str = Field(..., min_length=8, max_length=64)
    confirm_password: str = Field(..., min_length=1, max_length=64)

    @field_validator("org_name")
    @classmethod
    def _on(cls, v): return clean_org_name(v)

    @field_validator("organization_type")
    @classmethod
    def _ot(cls, v): return clean_text(v, "Organization type", 2, 100)

    @field_validator("address")
    @classmethod
    def _ad(cls, v): return clean_text(v, "Address", 10, 300)

    @field_validator("contact_person")
    @classmethod
    def _cp(cls, v): return clean_person_name(v, "Contact person", min_len=2, max_len=50)

    @field_validator("registration_no")
    @classmethod
    def _rn(cls, v): return clean_registration_no(v)

    @field_validator("contact_email")
    @classmethod
    def _ce(cls, v): return clean_email(str(v))

    @field_validator("contact_number")
    @classmethod
    def _cn(cls, v): return clean_ph_mobile(v)

    @field_validator("legitimacy_document_url")
    @classmethod
    def _url(cls, v): return clean_url(v)

    @model_validator(mode="after")
    def _check_password(self):
        if self.password != self.confirm_password:
            raise ValueError("Passwords do not match")
        validate_password_strength(
            self.password, email=self.contact_email, names=(self.contact_person,)
        )
        return self


class OrganizationResponse(BaseModel):
    organization_id: int
    org_name: str
    status: str

    class Config:
        from_attributes = True



class OrganizationAdminResponse(BaseModel):
    organization_id: int
    org_name: str
    organization_type: str
    address: str
    contact_person: str
    registration_no: str
    contact_email: str
    legitimacy_document_url: Optional[str] = None
    status: str
    approved_by_user_id: Optional[int] = None
    approved_at: Optional[datetime] = None
    created_at: datetime

    class Config:
        from_attributes = True