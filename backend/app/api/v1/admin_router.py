# routers/admin_router.py
from datetime import datetime, timezone
from typing import Literal, Optional

from fastapi import APIRouter, Depends, HTTPException, Query, Request, status
from pydantic import BaseModel, Field, model_validator
from sqlalchemy.orm import Session
from core.database import get_db
from core.auth import hash_password, require_role      # [NOT SPECIFIED — confirm exact signature]
from models.user_rbac_model import User
from models.role_model import Role
from models.organization_model import Organization
from models.barangay_model import Barangay
from models.audit_log_model import AuditLog
from core.audit import log_action
from schemas.user_schema import InternalAccountCreateRequest, UserResponse, INTERNAL_ROLES

router = APIRouter(prefix="/admin", tags=["admin"])

@router.post("/users", response_model=UserResponse, status_code=status.HTTP_201_CREATED)
def create_internal_account(
    payload: InternalAccountCreateRequest,
    db: Session = Depends(get_db),
    current_user: User = Depends(require_role("Administrator")),
):
    if payload.role_name not in INTERNAL_ROLES:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"role_name must be one of: {', '.join(sorted(INTERNAL_ROLES))}")

    if payload.role_name == "Barangay Receiving Representative" and payload.assigned_barangay_id is None:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST,
            detail="assigned_barangay_id is required for this role")

    if db.query(User).filter(User.email == payload.email).first():
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="Email already registered")

    role = db.query(Role).filter(Role.role_name == payload.role_name).first()
    if role is None:
        raise HTTPException(status_code=status.HTTP_500_INTERNAL_SERVER_ERROR, detail="Role configuration missing")

    new_user = User(
        first_name=payload.first_name, last_name=payload.last_name,
        email=payload.email, password_hash=hash_password(payload.password),
        contact_number=payload.contact_number, role_id=role.role_id,
        assigned_barangay_id=payload.assigned_barangay_id,   # works now — the model actually declares this column
    )
    db.add(new_user)
    db.flush()
    log_action(db, current_user, "CREATE ACCOUNT", "users", new_user.user_id,
               new={"email": new_user.email, "role": payload.role_name})
    db.commit()
    db.refresh(new_user)
    return new_user


ADMIN = "Administrator"


def _user_row(u: User, orgs: dict, barangays: dict) -> dict:
    org = orgs.get(u.organization_id)
    return {
        "user_id": u.user_id,
        "name": f"{u.first_name} {u.last_name}".strip(),
        "email": u.email,
        "contact_number": u.contact_number,
        "role": u.role.role_name if u.role else None,
        "organization": org.org_name if org else None,
        "organization_status": org.status if org else None,
        "assigned_barangay_id": u.assigned_barangay_id,
        "assigned_barangay": barangays.get(u.assigned_barangay_id),
        "is_active": u.is_active,
        "created_at": u.created_at,
    }


# UC-A1 Manage Internal Accounts: list accounts, view role, update status/details
@router.get("/users")
def list_users(
    role: Optional[str] = Query(default=None),
    q: Optional[str] = Query(default=None, description="search name or email"),
    db: Session = Depends(get_db),
    current_user: User = Depends(require_role(ADMIN)),
):
    query = db.query(User).join(Role, Role.role_id == User.role_id)
    if role:
        query = query.filter(Role.role_name == role)
    if q:
        like = f"%{q}%"
        query = query.filter(
            User.email.ilike(like) | User.first_name.ilike(like) | User.last_name.ilike(like)
        )
    orgs = {o.organization_id: o for o in db.query(Organization).all()}
    barangays = {b.barangay_id: b.barangay_name for b in db.query(Barangay).all()}
    return [_user_row(u, orgs, barangays) for u in query.order_by(User.user_id).all()]


class UserUpdate(BaseModel):
    is_active: Optional[bool] = None
    first_name: Optional[str] = Field(default=None, min_length=1, max_length=50)
    last_name: Optional[str] = Field(default=None, min_length=1, max_length=50)
    contact_number: Optional[str] = Field(default=None, min_length=7, max_length=15)
    assigned_barangay_id: Optional[int] = None


@router.patch("/users/{user_id}")
def update_user(
    user_id: int,
    payload: UserUpdate,
    request: Request,
    db: Session = Depends(get_db),
    current_user: User = Depends(require_role(ADMIN)),
):
    user = db.get(User, user_id)
    if user is None:
        raise HTTPException(status_code=404, detail="Account not found")  # UC-A1 3a
    changes = payload.model_dump(exclude_unset=True)
    if changes.get("is_active") is False and user.user_id == current_user.user_id:
        raise HTTPException(status_code=400, detail="You cannot deactivate your own account")
    if "assigned_barangay_id" in changes and changes["assigned_barangay_id"] is not None \
            and db.get(Barangay, changes["assigned_barangay_id"]) is None:
        raise HTTPException(status_code=400, detail="Barangay not found")
    old = {k: getattr(user, k) for k in changes}
    for k, v in changes.items():
        setattr(user, k, v)
    action = "UPDATE ACCOUNT"
    if set(changes) == {"is_active"}:
        action = "ACTIVATE ACCOUNT" if changes["is_active"] else "DEACTIVATE ACCOUNT"
    log_action(db, current_user, action, "users", user.user_id, old=old, new=changes, request=request)
    db.flush()
    orgs = {o.organization_id: o for o in db.query(Organization).all()}
    barangays = {b.barangay_id: b.barangay_name for b in db.query(Barangay).all()}
    return _user_row(user, orgs, barangays)


# UC-A2 Review Organization Registration
@router.get("/organizations")
def list_organizations(
    status_filter: Optional[str] = Query(default=None, alias="status"),
    db: Session = Depends(get_db),
    current_user: User = Depends(require_role(ADMIN)),
):
    query = db.query(Organization)
    if status_filter:
        query = query.filter(Organization.status == status_filter)
    # Latest Hold/Reject reason per organization (kept in audit_logs, no column).
    reasons = {}
    for log in (db.query(AuditLog)
                .filter(AuditLog.entity_type == "organizations",
                        AuditLog.action.in_(["HOLD ORGANIZATION", "REJECT ORGANIZATION",
                                             "APPROVE ORGANIZATION"]))
                .order_by(AuditLog.log_id)):
        reasons[log.entity_id] = (log.new_value or {}).get("reason")
    rows = []
    for o in query.order_by(Organization.created_at.desc()).all():
        rows.append({
            "organization_id": o.organization_id,
            "org_name": o.org_name,
            "organization_type": o.organization_type,
            "address": o.address,
            "contact_person": o.contact_person,
            "contact_email": o.contact_email,
            "registration_no": o.registration_no,
            "legitimacy_document_url": o.legitimacy_document_url,
            # UC-A2 alt 4a: flag applications with a missing document
            "document_missing": not (o.legitimacy_document_url or "").strip(),
            "status": o.status,
            "decision_reason": reasons.get(o.organization_id),
            "approved_at": o.approved_at,
            "created_at": o.created_at,
        })
    return rows


class OrganizationDecision(BaseModel):
    # Approved activates the account; Pending = hold; Rejected keeps it inactive (UC-A2 6a).
    decision: Literal["Approved", "Pending", "Rejected"]
    # Required for Hold and Reject so the organization can be told why.
    reason: Optional[str] = Field(default=None, max_length=500)

    @model_validator(mode="after")
    def _reason_required(self):
        self.reason = (self.reason or "").strip() or None
        if self.decision != "Approved" and self.reason is None:
            raise ValueError("Give a reason when you hold or reject an organization")
        return self


@router.post("/organizations/{organization_id}/decision")
def decide_organization(
    organization_id: int,
    payload: OrganizationDecision,
    request: Request,
    db: Session = Depends(get_db),
    current_user: User = Depends(require_role(ADMIN)),
):
    org = db.get(Organization, organization_id)
    if org is None:
        raise HTTPException(status_code=404, detail="Organization not found")
    old = {"status": org.status}
    org.status = payload.decision
    if payload.decision == "Approved":
        org.approved_by_user_id = current_user.user_id
        org.approved_at = datetime.now(timezone.utc)
    action = {"Approved": "APPROVE ORGANIZATION", "Pending": "HOLD ORGANIZATION",
              "Rejected": "REJECT ORGANIZATION"}[payload.decision]
    log_action(db, current_user, action, "organizations", org.organization_id,
               old=old, new={"status": org.status, "reason": payload.reason}, request=request)
    db.flush()
    return {"organization_id": org.organization_id, "org_name": org.org_name,
            "status": org.status, "reason": payload.reason}


# UC-A4 Monitor System Records: read-only activity logs
@router.get("/audit-logs")
def list_audit_logs(
    limit: int = Query(default=100, ge=1, le=500),
    entity_type: Optional[str] = Query(default=None),
    db: Session = Depends(get_db),
    current_user: User = Depends(require_role(ADMIN)),
):
    query = db.query(AuditLog, User.email).join(User, User.user_id == AuditLog.user_id)
    if entity_type:
        query = query.filter(AuditLog.entity_type == entity_type)
    return [
        {
            "log_id": log.log_id,
            "user": email,
            "action": log.action,
            "entity_type": log.entity_type,
            "entity_id": log.entity_id,
            "old_value": log.old_value,
            "new_value": log.new_value,
            "ip_address": log.ip_address,
            "timestamp": log.timestamp,
        }
        for log, email in query.order_by(AuditLog.log_id.desc()).limit(limit).all()
    ]
