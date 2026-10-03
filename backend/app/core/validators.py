"""Shared field cleaners. Each returns the normalized value or raises ValueError
(Pydantic turns that into a 422 with the message)."""
import re
from urllib.parse import urlparse

_L = "A-Za-zÀ-ÖØ-öø-ÿ"  # letters incl. Ñ/ñ and accents
_NAME_RE = re.compile(rf"^[{_L}]+(?:(?:\.\s|[ '\-])[{_L}]+)*\.?$")   # Juan, De la Cruz, O'Brien, Mary-Ann, J. R., Jr.
_ORG_NAME_RE = re.compile(rf"^[{_L}0-9][{_L}0-9 &.,'()\-/]{{1,149}}$")
_PH_MOBILE_RE = re.compile(r"^(?:\+63|63|0)9\d{9}$")
_EMP_ID_RE = re.compile(r"^[A-Z0-9][A-Z0-9\-]{3,19}$")
_REG_NO_RE = re.compile(r"^[A-Z0-9][A-Z0-9\-/ ]{3,99}$")


def _squash(v: str) -> str:
    return re.sub(r"\s+", " ", v.strip())


def clean_person_name(v: str, label: str = "Name", min_len: int = 2, max_len: int = 50) -> str:
    v = _squash(v)
    if not (min_len <= len(v) <= max_len):
        raise ValueError(f"{label} must be {min_len}-{max_len} characters")
    if not _NAME_RE.match(v):
        raise ValueError(f"{label} may only contain letters, spaces, hyphens, apostrophes and periods (no numbers or symbols)")
    if re.search(r"(.)\1{3,}", v, re.IGNORECASE):
        raise ValueError(f"{label} looks invalid (too many repeated characters)")
    return v


def clean_org_name(v: str) -> str:
    v = _squash(v)
    if not _ORG_NAME_RE.match(v):
        raise ValueError("Organization name must be 2-150 characters: letters, numbers, spaces and & . , ' ( ) - / only")
    return v


def clean_email(v: str) -> str:
    v = v.strip().lower()
    if len(v) > 150:
        raise ValueError("Email must be at most 150 characters")
    return v


def clean_ph_mobile(v: str) -> str:
    """Accepts 09171234567, +639171234567, 639171234567 (spaces/dashes ok).
    Always stores 09XXXXXXXXX (11 chars; fits users.contact_number VARCHAR(15))."""
    digits = re.sub(r"[\s\-()]", "", v)
    if not _PH_MOBILE_RE.match(digits):
        raise ValueError("Enter a valid Philippine mobile number, e.g. 09171234567 or +639171234567")
    return "0" + digits[-10:]


def clean_employee_id(v: str) -> str:
    v = v.strip().upper()
    if not _EMP_ID_RE.match(v):
        raise ValueError("Employee ID must be 4-20 characters: letters, numbers and hyphens only (e.g. CSWS-0042)")
    return v


def clean_registration_no(v: str) -> str:
    v = _squash(v).upper()
    if not _REG_NO_RE.match(v):
        raise ValueError("Registration number must be 4-100 characters: letters, numbers, spaces, - and / only")
    return v


def clean_text(v: str, label: str, min_len: int, max_len: int) -> str:
    v = _squash(v)
    if not (min_len <= len(v) <= max_len):
        raise ValueError(f"{label} must be {min_len}-{max_len} characters")
    return v


def clean_url(v: str | None) -> str | None:
    if v is None or not v.strip():
        return None
    v = v.strip()
    p = urlparse(v)
    if p.scheme not in ("http", "https") or not p.netloc or len(v) > 500:
        raise ValueError("Must be a valid http(s) link (max 500 characters)")
    return v