"""Barangay donation-sending info (adviser item 7). DISPLAY ONLY: NexaAid
never processes, holds or verifies money (Scope Limitation #5).

CHANGE LOG
- Concerns2.txt 2.1 (Castillo): account numbers follow provider standards.
  Bank: 10-16 digits. Other: 6-20 digits (was any 3-50 characters).
  Spaces or hyphens between digit groups are allowed. GCash/Maya unchanged
  (11-digit 09 mobile number). Must match mobile/lib/ui/donation_info.dart.
  Input-only: no column or migration change; existing rows still display.
"""
import re
from typing import Literal, Optional

from pydantic import BaseModel, Field, field_validator, model_validator

from core.validators import clean_ph_mobile, clean_text

NOTE = "NexaAid does not process or verify payments. Send directly to the barangay."

BANK_DIGITS = (10, 16)
OTHER_DIGITS = (6, 20)
_GROUPED_DIGITS = re.compile(r"[0-9]+(?:[ \-][0-9]+)*")


def _account_digits(n: str, min_digits: int, max_digits: int, label: str) -> str:
    if not _GROUPED_DIGITS.fullmatch(n):
        raise ValueError(f"{label}: numbers only (spaces or hyphens between groups are OK)")
    count = len(re.sub(r"[ \-]", "", n))
    if not min_digits <= count <= max_digits:
        raise ValueError(f"{label}: must be {min_digits}-{max_digits} digits")
    return n


class DonationInfoIn(BaseModel):
    """Not always a QR: the barangay may give a QR, account details,
    instructions, or any mix. At least one of QR / account number /
    instructions is required."""
    provider: Optional[Literal["GCash", "Maya", "Bank", "Other"]] = None
    account_name: Optional[str] = None
    account_number: Optional[str] = None
    instructions: Optional[str] = Field(default=None, max_length=500)
    qr_file_id: Optional[str] = Field(default=None, min_length=36, max_length=36)

    @field_validator("account_name", "account_number", "instructions", "qr_file_id", mode="before")
    @classmethod
    def _blank_is_none(cls, v):
        return None if isinstance(v, str) and not v.strip() else v

    @field_validator("account_name")
    @classmethod
    def _name(cls, v):
        return None if v is None else clean_text(v, "Account name", 2, 100)

    @field_validator("instructions")
    @classmethod
    def _instr(cls, v):
        return None if v is None else clean_text(v, "Instructions", 5, 500)

    @model_validator(mode="after")
    def _check(self):
        if not (self.qr_file_id or self.account_number or self.instructions):
            raise ValueError("Add a QR code, an account number, or instructions")
        if self.account_number:
            if not self.provider:
                raise ValueError("Choose the provider for the account number")
            if not self.account_name:
                raise ValueError("Enter the account name for the account number")
            n = self.account_number.strip()
            if self.provider in ("GCash", "Maya"):
                self.account_number = clean_ph_mobile(n)          # 09XXXXXXXXX
            elif self.provider == "Bank":
                self.account_number = _account_digits(n, *BANK_DIGITS, "Bank account number")
            else:
                self.account_number = _account_digits(n, *OTHER_DIGITS, "Account number")
        return self