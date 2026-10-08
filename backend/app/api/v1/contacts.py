"""
app/api/v1/contacts.py

GET /contacts/sms-receivers  (NEW, Scope 2.4 / UC-CD1 alt 11b / UC-A3 alt 8a)
    The CSWS Disaster Unit sends SMS reports when it has no internet, and the
    Administrator reviews and encodes them. So the Disaster Unit needs the
    Administrators' numbers. The app saves this list on the phone so the
    "Send report by SMS" screen still works offline.

GET /contacts/disaster-unit  (EXISTING, unchanged)
    Built for the panel idea that barangay reps send SMS reports. The team
    decided to follow the manuscript instead (Scope 1.3 / UC-B1: barangay
    reps do not create reports; see claude/sms-reporting-decision.md), so the
    app no longer calls it. Kept so nothing else breaks; safe to remove later.

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
    return _contacts_with_role(db, DISASTER_UNIT)


@router.get("/sms-receivers", response_model=List[DisasterUnitContact])
def sms_receivers(
    db: Session = Depends(get_db),
    current_user=Depends(get_current_user),
):
    if _role_name(current_user) not in _SMS_SENDERS:
        raise HTTPException(status.HTTP_403_FORBIDDEN, "Not allowed")
    return _contacts_with_role(db, ADMINISTRATOR, skip_blank=True)