"""
app/api/v1/contacts.py
Appendix H 2.2: barangay reps must see the CSWS Disaster Unit's phone number
so they can send the emergency SMS report.

Only the name and contact number of active Disaster Unit users are returned.
This is deliberately not the full user list.
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
# Roles allowed to read the number. Barangay reps need it; the others are
# harmless to include and handy for testing.
_ALLOWED = {"Barangay Receiving Representative", "CSWS Disaster Unit", "Administrator"}


class DisasterUnitContact(BaseModel):
    name: str
    contact_number: str


@router.get("/disaster-unit", response_model=List[DisasterUnitContact])
def disaster_unit_contacts(
    db: Session = Depends(get_db),
    current_user=Depends(get_current_user),
):
    role_name = getattr(getattr(current_user, "role", None), "role_name", None)
    if role_name not in _ALLOWED:
        raise HTTPException(status.HTTP_403_FORBIDDEN, "Not allowed")

    rows = (
        db.query(User)
        .join(Role, Role.role_id == User.role_id)
        .filter(Role.role_name == DISASTER_UNIT, User.is_active.is_(True))
        .order_by(User.user_id)
        .all()
    )
    return [
        DisasterUnitContact(
            name=f"{u.first_name} {u.last_name}".strip(),
            contact_number=u.contact_number,
        )
        for u in rows
    ]