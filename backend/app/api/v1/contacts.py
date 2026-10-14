"""
app/api/v1/contacts.py

GET /contacts/disaster-unit  (Oct 12 team decision, claude/sms-reporting-decision.md)
    Barangay Receiving Representatives with no internet send a structured SMS
    report to a CSWS Disaster Unit member, who encodes it (POST /reports/sms).
    So the rep needs the Disaster Unit's names and numbers. The app saves
    this list on the phone so the "SMS report" screen still works offline.
    Members without a contact number are left out.

GET /contacts/sms-receivers  (Oct 8, no longer used by the app)
    The Administrators' numbers, from when the Disaster Unit texted the
    Administrator. Kept so nothing else breaks; safe to remove later.

Only names and contact numbers are returned, never the full user records.
"""

from typing import List

from fastapi import APIRouter, Depends, HTTPException, status
from pydantic import BaseModel
from sqlalchemy.orm import Session, joinedload

from core.database import get_db
from core.auth import get_current_user
from models.user_rbac_model import User
from models.role_model import Role

router = APIRouter(prefix="/contacts", tags=["contacts"])

DISASTER_UNIT = "CSWS Disaster Unit"
ADMINISTRATOR = "Administrator"
# Roles allowed to read the Disaster Unit numbers (existing endpoint).
_ALLOWED = {"Barangay Receiving Representative", "CSWS Disaster Unit", "Administrator"}
# Roles allowed to read the SMS receivers: the senders and the admins themselves.
_SMS_SENDERS = {DISASTER_UNIT, ADMINISTRATOR}


class DisasterUnitContact(BaseModel):
    name: str
    contact_number: str


def _role_name(user) -> str | None:
    return getattr(getattr(user, "role", None), "role_name", None)


def _contacts_with_role(
    db: Session, role_name: str, skip_blank: bool = False
) -> List[DisasterUnitContact]:
    rows = (
        db.query(User)
        .join(Role, Role.role_id == User.role_id)
        .filter(Role.role_name == role_name, User.is_active.is_(True))
        .order_by(User.user_id)
        .all()
    )
    return [
        DisasterUnitContact(
            name=f"{u.first_name} {u.last_name}".strip(),
            contact_number=u.contact_number,
        )
        for u in rows
        if not skip_blank or (u.contact_number or "").strip()
    ]


@router.get("/disaster-unit", response_model=List[DisasterUnitContact])
def disaster_unit_contacts(
    db: Session = Depends(get_db),
    current_user=Depends(get_current_user),
):
    if _role_name(current_user) not in _ALLOWED:
        raise HTTPException(status.HTTP_403_FORBIDDEN, "Not allowed")
    return _contacts_with_role(db, DISASTER_UNIT, skip_blank=True)


@router.get("/sms-receivers", response_model=List[DisasterUnitContact])
def sms_receivers(
    db: Session = Depends(get_db),
    current_user=Depends(get_current_user),
):
    if _role_name(current_user) not in _SMS_SENDERS:
        raise HTTPException(status.HTTP_403_FORBIDDEN, "Not allowed")
    return _contacts_with_role(db, ADMINISTRATOR, skip_blank=True)