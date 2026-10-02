# routers/admin_router.py
from datetime import datetime, timezone
from typing import List, Optional

from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy import func, text
from sqlalchemy.orm import Session, joinedload

from core.database import get_db
from core.auth import hash_password, require_role
from core.passwords import generate_temp_password
from core.email_service import send_temp_password_email, commit_after_email
from models.user_rbac_model import User
from models.role_model import Role
from models.organization_model import Organization
from schemas.user_schema import (
    InternalAccountCreateRequest, UserResponse, AdminUserResponse, INTERNAL_ROLES,
)
from schemas.organization_schema import OrganizationAdminResponse

router = APIRouter(prefix="/admin", tags=["admin"])

# Must match roles.role_name exactly. Your other routers use "admin";
# confirm which string is really in the table and use it everywhere.
ADMIN_ROLE = "Administrator"


def _to_admin_user(u: User) -> AdminUserResponse:
    return AdminUserResponse(
        user_id=u.user_id,
        first_name=u.first_name,
        last_name=u.last_name,
        email=u.email,
        role_id=u.role_id,
        role_name=u.role.role_name,
        assigned_barangay_id=u.assigned_barangay_id,
        employee_id=getattr(u, "employee_id", None),
        is_active=u.is_active,
        created_at=u.created_at,
    )


# ---------------------------------------------------------------------------
# Accounts
# ---------------------------------------------------------------------------
@router.post("/users", response_model=UserResponse, status_code=status.HTTP_201_CREATED)
def create_internal_account(
    payload: InternalAccountCreateRequest,
    db: Session = Depends(get_db),
    current_user: User = Depends(require_role(ADMIN_ROLE)),
):
    if payload.role_name not in INTERNAL_ROLES:
        raise HTTPException(status_code=400,
            detail=f"role_name must be one of: {', '.join(sorted(INTERNAL_ROLES))}")

    is_brgy = payload.role_name == "Barangay Receiving Representative"
    if is_brgy and payload.assigned_barangay_id is None:
        raise HTTPException(status_code=400, detail="assigned_barangay_id is required for this role")
    if not is_brgy and payload.assigned_barangay_id is not None:
        raise HTTPException(status_code=400,
            detail="assigned_barangay_id is only for Barangay Receiving Representative")

    # Raw SQL on purpose: the Barangay stub model in models/report.py has a `name`
    # column, but the real table column is `barangay_name`.
    if is_brgy and not db.execute(
        text("SELECT 1 FROM barangays WHERE barangay_id = :i"),
        {"i": payload.assigned_barangay_id},
    ).first():
        raise HTTPException(status_code=400, detail="Barangay not found")

    email = payload.email.strip().lower()
    if db.query(User).filter(func.lower(User.email) == email).first():
        raise HTTPException(status_code=409, detail="Email already registered")
    if db.query(User).filter(User.employee_id == payload.employee_id).first():
        raise HTTPException(status_code=409, detail="Employee ID already registered")

    role = db.query(Role).filter(Role.role_name == payload.role_name).first()
    if role is None:
        raise HTTPException(status_code=500, detail="Role configuration missing")

    temp_password = generate_temp_password()
    new_user = User(
        first_name=payload.first_name, last_name=payload.last_name,
        email=email, password_hash=hash_password(temp_password),
        contact_number=payload.contact_number, role_id=role.role_id,
        assigned_barangay_id=payload.assigned_barangay_id,
        employee_id=payload.employee_id,
        must_change_password=True,
    )
    db.add(new_user)
    commit_after_email(db, lambda: send_temp_password_email(
        new_user.email, new_user.first_name, temp_password, payload.role_name))
    db.refresh(new_user)
    return new_user


@router.get("/users", response_model=List[AdminUserResponse])
def list_users(
    db: Session = Depends(get_db),
    current_user: User = Depends(require_role(ADMIN_ROLE)),
):
    users = (
        db.query(User)
        .options(joinedload(User.role))
        .order_by(User.created_at.desc())
        .all()
    )
    return [_to_admin_user(u) for u in users]


# ---------------------------------------------------------------------------
# Organizations (UC-A2)
# ---------------------------------------------------------------------------
@router.get("/organizations", response_model=List[OrganizationAdminResponse])
def list_organizations(
    status_filter: Optional[str] = Query(default=None, alias="status"),
    db: Session = Depends(get_db),
    current_user: User = Depends(require_role(ADMIN_ROLE)),
):
    q = db.query(Organization)
    if status_filter:
        q = q.filter(Organization.status == status_filter)
    return q.order_by(Organization.created_at.desc()).all()


def _decide_organization(db: Session, organization_id: int, new_status: str, admin: User):
    org = db.get(Organization, organization_id)
    if org is None:
        raise HTTPException(status_code=404, detail="Organization not found")
    if org.status != "Pending":
        raise HTTPException(status_code=409,
            detail=f"Organization is already '{org.status}'; only Pending applications can be decided")
    org.status = new_status
    org.approved_by_user_id = admin.user_id
    org.approved_at = datetime.now(timezone.utc)
    db.commit()
    db.refresh(org)
    return org


@router.post("/organizations/{organization_id}/approve", response_model=OrganizationAdminResponse)
def approve_organization(
    organization_id: int,
    db: Session = Depends(get_db),
    current_user: User = Depends(require_role(ADMIN_ROLE)),
):
    return _decide_organization(db, organization_id, "Approved", current_user)


@router.post("/organizations/{organization_id}/reject", response_model=OrganizationAdminResponse)
def reject_organization(
    organization_id: int,
    db: Session = Depends(get_db),
    current_user: User = Depends(require_role(ADMIN_ROLE)),
):
    return _decide_organization(db, organization_id, "Rejected", current_user)