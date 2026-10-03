# schemas/user_schema.py
from typing import Literal, Optional

from pydantic import BaseModel, EmailStr, Field, field_validator, model_validator

from core.names import capitalize_words
from core.passwords import validate_password_strength
from core.validators import clean_email, clean_person_name, clean_ph_mobile
from schemas.upload_schema import UploadRef

# UC-D1 step 3: kinds of valid ID a donor may upload (stored in users.id_type).
ID_TYPES = (
    "PhilSys National ID", "Driver's License", "Passport", "UMID", "Postal ID",
    "Voter's ID", "PRC ID", "School ID", "Other",
)
IdType = Literal[ID_TYPES]


def clean_name(value: str, label: str) -> str:
    """Letters only (core/validators.py), then capitalize each word."""
    return capitalize_words(clean_person_name(value, label))


class DonorRegisterRequest(BaseModel):
    """UC-D1 Register Individual Donor. The account is active right away
    (steps 6-7); the ID photos are kept for the Administrator (UC-A1)."""
    first_name: str
    last_name: str
    email: EmailStr
    contact_number: str
    # Donors choose their own password (staff get one from the Administrator).
    password: str = Field(..., min_length=8, max_length=64)
    confirm_password: str = Field(..., min_length=1, max_length=64)
    # Step 3: valid ID, front and back, uploaded first with POST /uploads.
    id_type: IdType
    id_front: UploadRef
    id_back: UploadRef
    # RA 10173 (Data Privacy Act): the ID photos are sensitive personal information.
    consent: bool

    @field_validator("first_name")
    @classmethod
    def _fn(cls, v): return clean_name(v, "First name")

    @field_validator("last_name")
    @classmethod
    def _ln(cls, v): return clean_name(v, "Last name")

    @field_validator("email")
    @classmethod
    def _em(cls, v): return clean_email(str(v))

    @field_validator("contact_number")
    @classmethod
    def _cn(cls, v): return clean_ph_mobile(v)  # accepts +639..., stores 09XXXXXXXXX

    @field_validator("consent")
    @classmethod
    def _consent(cls, v):
        if v is not True:
            raise ValueError("You must agree to the processing of your personal data (RA 10173)")
        return v

    @model_validator(mode="after")
    def _check(self):
        if self.id_front.file_id == self.id_back.file_id:
            raise ValueError("Upload the front and the back of your ID as two separate photos")
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


class LoginRequest(BaseModel):
    # Fields must be indented under the class line, or Python raises
    # "IndentationError: expected an indented block after class definition".
    email: EmailStr
    password: str