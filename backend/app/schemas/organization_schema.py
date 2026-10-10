# schemas/organization_schema.py
from typing import Literal, Optional

from pydantic import BaseModel, EmailStr, Field, field_validator, model_validator

from core.names import capitalize_org_words
from core.passwords import validate_password_strength
from core.validators import (
    clean_email, clean_org_name, clean_ph_mobile, clean_registration_no, clean_text,
)
from schemas.upload_schema import UploadRef
from schemas.user_schema import clean_name

ORGANIZATION_TYPES = (
    "NGO", "Religious", "Civic", "Private/CSR", "Academic", "Government", "Other",
)

# CHANGED: these types are not registered like private organizations, so the
# registration number and supporting document are not used for them. For every
# other type both are optional.
TYPES_WITHOUT_REGISTRATION = ("Government",)


class OrganizationRegisterRequest(BaseModel):
    """UC-A2 (the organization side). Capstone 2 adviser comments 1.1 and
    1.3: the registration number and supporting document are optional (and
    ignored for Government), and the account is validated automatically. The
    Administrator's view is for review only."""

    org_name: str
    organization_type: Literal[ORGANIZATION_TYPES]
    # Required when organization_type is "Other"; stored as "Other: <text>".
    organization_type_other: Optional[str] = None
    # TODO(Dave Hoyohoy): switch to the structured AddressField once it exists.
    address: Optional[str] = None
    contact_first_name: str
    contact_last_name: str
    registration_no: Optional[str] = None
    contact_email: EmailStr
    contact_number: str
    password: str = Field(..., min_length=8, max_length=64)
    confirm_password: str = Field(..., min_length=1, max_length=64)
    # Supporting document, uploaded first with POST /uploads (photo or PDF).
    # Optional.
    legitimacy_document: Optional[UploadRef] = None
    # RA 10173 (Data Privacy Act)
    consent: bool
    # D3: Terms and Conditions agreement. The server stores when it was accepted.
    accepted_terms: bool

    # Capitalize the first letter of every word (PM rule) after the existing
    # cleaning/validation. The rest of each word is kept as typed ("NGO").
    @field_validator("org_name")
    @classmethod
    def _on(cls, v):
        return capitalize_org_words(clean_org_name(v))

    @field_validator("address")
    @classmethod
    def _ad(cls, v):
        if v is None or not v.strip():
            return None
        return clean_text(v, "Address", 10, 300)

    @field_validator("contact_first_name")
    @classmethod
    def _fn(cls, v): return clean_name(v, "Contact person's first name")

    @field_validator("contact_last_name")
    @classmethod
    def _ln(cls, v): return clean_name(v, "Contact person's last name")

    # Optional: an empty value becomes None, a filled one is still validated.
    @field_validator("registration_no")
    @classmethod
    def _rn(cls, v):
        if v is None or not v.strip():
            return None
        return clean_registration_no(v)

    @field_validator("contact_email")
    @classmethod
    def _ce(cls, v): return clean_email(str(v))

    @field_validator("contact_number")
    @classmethod
    def _cn(cls, v): return clean_ph_mobile(v)

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

        # CHANGED: nothing is required. Government does not use the two
        # fields, so anything sent through the API is discarded.
        if self.organization_type in TYPES_WITHOUT_REGISTRATION:
            self.registration_no = None
            self.legitimacy_document = None

        if self.organization_type == "Other":
            if not (self.organization_type_other or "").strip():
                raise ValueError("Please specify the organization type")
            self.organization_type_other = clean_text(
                self.organization_type_other, "Organization type", 2, 90)
        else:
            self.organization_type_other = None
        if self.password != self.confirm_password:
            raise ValueError("Passwords do not match")
        validate_password_strength(
            self.password, email=self.contact_email,
            names=(self.contact_first_name, self.contact_last_name),
        )
        return self

    @property
    def organization_type_label(self) -> str:
        """Value saved in organizations.organization_type (VARCHAR 100)."""
        if self.organization_type == "Other":
            return f"Other: {self.organization_type_other}"
        return self.organization_type

    @property
    def contact_person(self) -> str:
        """organizations.contact_person keeps the full name in one column."""
        return f"{self.contact_first_name} {self.contact_last_name}"


class OrganizationResponse(BaseModel):
    organization_id: int
    org_name: str
    status: str

    class Config:
        from_attributes = True