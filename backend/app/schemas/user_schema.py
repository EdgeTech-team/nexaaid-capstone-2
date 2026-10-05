# schemas/user_schema.py
from typing import Literal, Optional

from pydantic import BaseModel, EmailStr, Field, field_validator, model_validator

from core.names import capitalize_words
from core.passwords import validate_password_strength
from core.validators import clean_email, clean_employee_id, clean_person_name, clean_ph_mobile
from schemas.upload_schema import UploadRef

# UC-D1 step 3: kinds of valid ID a donor may upload (stored in users.id_type).
# D1: the ID type is no longer asked during registration. The list and the
# database column are kept (admin screens show "Not given" when it is empty),
# but the field is optional and the app does not send it any more.
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
    # The strength rules are in core/passwords.py (validate_password_strength).
    password: str = Field(..., min_length=8, max_length=64)
    confirm_password: str = Field(..., min_length=1, max_length=64)
    # D1: optional and no longer sent by the app. Kept so old clients and the
    # existing users.id_type column keep working.
    id_type: Optional[IdType] = None
    # Step 3: valid ID, front and back, uploaded first with POST /uploads.
    id_front: UploadRef
    id_back: UploadRef
    # RA 10173 (Data Privacy Act): the ID photos are sensitive personal information.
    consent: bool
    # D3: Terms and Conditions agreement. The server stores when it was accepted.
    accepted_terms: bool

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

    @field_validator("accepted_terms")
    @classmethod
    def _terms(cls, v):
        if v is not True:
            raise ValueError("You must accept the Terms and Conditions")
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
    employee_id: Optional[str] = None

    class Config:
        from_attributes = True


INTERNAL_ROLES = {
    "CSWS Disaster Unit", "CSWS Main Office", "CMO Representative",
    "DRRMO Logistics Support", "Barangay Receiving Representative",
}


BARANGAY_REP = "Barangay Receiving Representative"


class InternalAccountCreateRequest(BaseModel):
    """UC-A1 step 4: the Administrator creates an office-based account.
    Same name / phone / email rules as registration."""
    first_name: str
    last_name: str
    email: EmailStr
    password: str = Field(..., min_length=8, max_length=64)  # temporary password
    contact_number: str
    role_name: str
    assigned_barangay_id: Optional[int] = Field(default=None, gt=0)
    employee_id: str
    # Uploaded first by the Administrator (purpose employee_id_card).
    employee_id_card: UploadRef

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
    def _cn(cls, v): return clean_ph_mobile(v)

    @field_validator("employee_id")
    @classmethod
    def _emp(cls, v): return clean_employee_id(v)  # 4-20 letters/numbers/hyphens, upper case

    @model_validator(mode="after")
    def _check(self):
        if self.role_name not in INTERNAL_ROLES:
            raise ValueError(f"Role must be one of: {', '.join(sorted(INTERNAL_ROLES))}")
        if self.role_name == BARANGAY_REP and self.assigned_barangay_id is None:
            raise ValueError("Choose the assigned barangay for a Barangay Receiving Representative")
        if self.role_name != BARANGAY_REP:
            self.assigned_barangay_id = None
        validate_password_strength(
            self.password, email=self.email, names=(self.first_name, self.last_name))
        return self


class AccountUpdateRequest(BaseModel):
    """UC-A1 step 5: the Administrator updates account details or status.
    Every field is optional (PATCH); invalid changes are rejected with 422
    (alt 5a). Role, barangay and employee fields are for internal accounts."""
    first_name: Optional[str] = None
    last_name: Optional[str] = None
    email: Optional[EmailStr] = None
    contact_number: Optional[str] = None
    role_name: Optional[str] = None
    assigned_barangay_id: Optional[int] = Field(default=None, gt=0)
    employee_id: Optional[str] = None
    employee_id_card: Optional[UploadRef] = None  # replaces the current card
    is_active: Optional[bool] = None

    @field_validator("first_name")
    @classmethod
    def _fn(cls, v): return None if v is None else clean_name(v, "First name")

    @field_validator("last_name")
    @classmethod
    def _ln(cls, v): return None if v is None else clean_name(v, "Last name")

    @field_validator("email")
    @classmethod
    def _em(cls, v): return None if v is None else clean_email(str(v))

    @field_validator("contact_number")
    @classmethod
    def _cn(cls, v): return None if v is None else clean_ph_mobile(v)

    @field_validator("employee_id")
    @classmethod
    def _emp(cls, v): return None if v is None else clean_employee_id(v)

    @field_validator("role_name")
    @classmethod
    def _role(cls, v):
        if v is not None and v not in INTERNAL_ROLES:
            raise ValueError(f"Role must be one of: {', '.join(sorted(INTERNAL_ROLES))}")
        return v


class LoginRequest(BaseModel):
    # Fields must be indented under the class line, or Python raises
    # "IndentationError: expected an indented block after class definition".
    email: EmailStr
    password: str