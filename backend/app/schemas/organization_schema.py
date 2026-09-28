# schemas/organization_schema.py
from pydantic import BaseModel, EmailStr, Field

class OrganizationRegisterRequest(BaseModel):
    org_name: str = Field(..., min_length=1, max_length=150)
    organization_type: str = Field(..., min_length=1, max_length=100)
    address: str = Field(..., min_length=1)
    contact_person: str = Field(..., min_length=1, max_length=150)
    registration_no: str = Field(..., min_length=1, max_length=100)
    contact_email: EmailStr = Field(..., max_length=150)
    legitimacy_document_url: str | None = None
    password: str = Field(..., min_length=8, max_length=128)
    contact_number: str = Field(..., min_length=7, max_length=20)

class OrganizationResponse(BaseModel):
    organization_id: int
    org_name: str
    status: str

    class Config:
        from_attributes = True