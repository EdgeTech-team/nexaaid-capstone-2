# schemas/accounts/organization_schema.py
from typing import Literal, Optional

from pydantic import BaseModel, EmailStr, Field, field_validator, model_validator

from core.common.names import capitalize_org_words
from core.security.passwords import validate_password_strength
from core.common.usernames import clean_username
from core.common.validators import (
    clean_email, clean_org_name, clean_ph_mobile, clean_registration_no, clean_text,
)
from schemas.uploads.upload_schema import UploadRef
from schemas.accounts.user_schema import clean_name
from pydantic import ConfigDict

# NF-008 (D6, agreement A6): a fixed list with two categories, shown as a
# grouped dropdown. organizations.organization_category is set from it.
GOVERNMENT = "Government"
NON_GOVERNMENT = "Non-government"
OTHER_TYPE = "Other (specify)"
GOVERNMENT_TYPES = (
    "Barangay / Barangay Council",
    "City or Municipal Government Office",
    "National Government Agency",
    "Public School or State University",
    "Government-Owned or Controlled Corporation",
)
NON_GOVERNMENT_TYPES = (
    "Non-Profit / NGO / Foundation",
    "Religious Organization",
    "Private Company or Business",
    "Private School or University",
    "Civic or Community Group",
    OTHER_TYPE,                       # counted as Non-government
)
ORGANIZATION_TYPES = GOVERNMENT_TYPES + NON_GOVERNMENT_TYPES
ORGANIZATION_TYPE_GROUPS = {GOVERNMENT: GOVERNMENT_TYPES, NON_GOVERNMENT: NON_GOVERNMENT_TYPES}

# Values older app versions send (the old free list), mapped to the new list.
LEGACY_TYPES = {
    "NGO": "Non-Profit / NGO / Foundation",
    "Religious": "Religious Organization",
    "Civic": "Civic or Community Group",
    "Private/CSR": "Private Company or Business",
    "Academic": "Private School or University",
    "Government": "City or Municipal Government Office",
    "Other": OTHER_TYPE,
}

GOVERNMENT_DOCUMENT_REQUIRED = (
    "Government organizations must upload one supporting document: an authorization "
    "or endorsement letter on office letterhead, or the contact person's office ID."
)


def organization_category(organization_type: str) -> str:
    """'Government' or 'Non-government' for a stored organization type
    (old free labels included; anything unknown is Non-government)."""
    label = (organization_type or "").strip()
    if label == GOVERNMENT or label in GOVERNMENT_TYPES:
        return GOVERNMENT
    return NON_GOVERNMENT


class OrganizationRegisterRequest(BaseModel):
    """UC-A2 (the organization side). The account signs in at once
    (Capstone 2 adviser comment 1.3) and starts Unverified until the
    Administrator reviews it. NF-008 (D6): every organization uploads the
    contact person's government ID, like an individual donor; Government
    types also upload one supporting document. For Non-government types the
    document stays optional (adviser comment 1.1). The registration form no
    longer asks for a registration number, but the field is still accepted."""

    org_name: str
    # One of ORGANIZATION_TYPES (old app values are mapped, LEGACY_TYPES).
    organization_type: str
    # Required for "Other (specify)"; stored as "Other: <text>".
    organization_type_other: Optional[str] = None
    # TODO(Dave Hoyohoy): switch to the structured AddressField once it exists.
    address: Optional[str] = None
    contact_first_name: str
    contact_last_name: str
    registration_no: Optional[str] = None
    contact_email: EmailStr
    # Login name for the organization account (the contact person's email is
    # not always the person using the account). The app requires it; the API
    # still accepts a request without it so older clients and tests keep
    # working. To make it required here too, change the default to "..." and
    # remove the None handling in _un below.
    username: Optional[str] = None
    contact_number: str
    password: str = Field(..., min_length=8, max_length=64)
    confirm_password: str = Field(..., min_length=1, max_length=64)
    # Supporting document, uploaded first with POST /uploads (photo or PDF).
    # Required for Government types, optional for the others.
    legitimacy_document: Optional[UploadRef] = None
    # NF-008: the contact person's government ID, front and back, uploaded
    # first with POST /uploads (purposes id_front / id_back). Required.
    id_front: UploadRef
    id_back: UploadRef
    id_type: Optional[str] = Field(default=None, max_length=40)
    # RA 10173 (Data Privacy Act)
    consent: bool
    # D3: Terms and Conditions agreement. The server stores when it was accepted.
    accepted_terms: bool

    # Capitalize the first letter of every word (PM rule) after the existing
    # cleaning/validation. The rest of each word is kept as typed ("NGO").
    @field_validator("organization_type")
    @classmethod
    def _ot(cls, v):
        label = LEGACY_TYPES.get((v or "").strip(), (v or "").strip())
        if label not in ORGANIZATION_TYPES:
            raise ValueError("Choose the organization type from the list")
        return label

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

    # Optional here, but a filled one must follow the username rules and is
    # saved in lowercase.
    @field_validator("username")
    @classmethod
    def _un(cls, v):
        if v is None or not v.strip():
            return None
        return clean_username(v)

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

        # NF-008: Government types must upload a supporting document.
        if self.category == GOVERNMENT and self.legitimacy_document is None:
            raise ValueError(GOVERNMENT_DOCUMENT_REQUIRED)

        if self.organization_type == OTHER_TYPE:
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
        if self.organization_type == OTHER_TYPE:
            return f"Other: {self.organization_type_other}"
        return self.organization_type

    @property
    def category(self) -> str:
        """organizations.organization_category."""
        return organization_category(self.organization_type)

    @property
    def contact_person(self) -> str:
        """organizations.contact_person keeps the full name in one column."""
        return f"{self.contact_first_name} {self.contact_last_name}"


class OrganizationResponse(BaseModel):
    organization_id: int
    org_name: str
    status: str

    model_config = ConfigDict(from_attributes=True)
