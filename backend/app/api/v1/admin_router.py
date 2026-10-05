# routers/admin_router.py
from datetime import datetime, timezone
from typing import Literal, Optional

from fastapi import APIRouter, BackgroundTasks, Depends, HTTPException, Query, Request, status
from pydantic import BaseModel, Field, model_validator
from sqlalchemy import func
from sqlalchemy.orm import Session
from core import email as mail_service
from core.database import get_db
from core.auth import hash_password, require_role
from core.uploads import transfer_upload
from models.user_rbac_model import User
from models.role_model import Role
from models.organization_model import Organization
from models.barangay_model import Barangay
from models.audit_log_model import AuditLog
from core.audit import log_action
from schemas.user_schema import (
    AccountUpdateRequest, BARANGAY_REP, INTERNAL_ROLES, InternalAccountCreateRequest, UserResponse,
)
from core.notifications import notify_event

router = APIRouter(prefix="/admin", tags=["admin"])


def _queue_email(background_tasks: BackgroundTasks, to: Optional[str], subject: str, body: str) -> None:
    """Send after the response, so a slow Gmail connection never delays the
    request. Only plain strings are passed (never the db session), and
    send_email() never raises or logs the body."""
    if to:
        background_tasks.add_task(mail_service.send_email, to, subject, body)


def _email_in_use(db: Session, email: str, except_user_id: Optional[int] = None) -> bool:
    q = db.query(User).filter(func.lower(User.email) == email.lower())
    if except_user_id is not None:
        q = q.filter(User.user_id != except_user_id)
    return q.first() is not None


def _employee_id_in_use(db: Session, employee_id: str, except_user_id: Optional[int] = None) -> bool:
    q = db.query(User).filter(User.employee_id == employee_id)
    if except_user_id is not None:
        q = q.filter(User.user_id != except_user_id)
    return q.first() is not None


def _check_barangay(db: Session, barangay_id: int) -> None:
    if db.get(Barangay, barangay_id) is None:
        raise HTTPException(status_code=422, detail="Barangay not found")


@router.post("/users", response_model=UserResponse, status_code=status.HTTP_201_CREATED)
def create_internal_account(
    payload: InternalAccountCreateRequest,
    request: Request,
    background_tasks: BackgroundTasks,
    db: Session = Depends(get_db),
    current_user: User = Depends(require_role("Administrator")),
):
    """UC-A1 step 4. Role, barangay and password rules are in the schema."""
    if payload.assigned_barangay_id is not None:
        _check_barangay(db, payload.assigned_barangay_id)
    if _email_in_use(db, payload.email):
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="Email already in use")
    if _employee_id_in_use(db, payload.employee_id):
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="Employee ID already in use")

    role = db.query(Role).filter(Role.role_name == payload.role_name).first()
    if role is None:
        raise HTTPException(status_code=status.HTTP_500_INTERNAL_SERVER_ERROR, detail="Role configuration missing")

    new_user = User(
        first_name=payload.first_name, last_name=payload.last_name,
        email=payload.email, password_hash=hash_password(payload.password),
        contact_number=payload.contact_number, role_id=role.role_id,
        assigned_barangay_id=payload.assigned_barangay_id,
        employee_id=payload.employee_id,
    )
    db.add(new_user)
    db.flush()
    # The card was uploaded by this Administrator; the staff member owns it now.
    card = transfer_upload(db, payload.employee_id_card.file_id, current_user, new_user,
                           "employee_id_card")
    log_action(db, current_user, "CREATE ACCOUNT", "users", new_user.user_id,
               new={"email": new_user.email, "role": payload.role_name,
                    "employee_id": new_user.employee_id,
                    "assigned_barangay_id": new_user.assigned_barangay_id,
                    "employee_id_card": card.file_id},
               request=request)
    notify_event(db, new_user.user_id, "account_created", "user", new_user.user_id)

    # The new staff member gets their login details by email.
    _queue_email(
        background_tasks, new_user.email,
        "Your NexaAid account is ready",
        f"Hello {payload.first_name},\n\n"
        f"An administrator created your NexaAid account ({payload.role_name}).\n\n"
        f"Login email: {payload.email}\n"
        f"Temporary password: {payload.password}\n\n"
        "Please sign in and change your password right away.\n\n"
        "NexaAid",
    )
    db.flush()
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
        "employee_id": u.employee_id,
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


def _active_admins(db: Session) -> int:
    # Counted in Python: there are only a few admins, and it reads is_active
    # the same way on Postgres and on the SQLite test database.
    admins = db.query(User).join(Role, Role.role_id == User.role_id).filter(Role.role_name == ADMIN)
    return sum(1 for u in admins if u.is_active)


@router.patch("/users/{user_id}")
def update_user(
    user_id: int,
    payload: AccountUpdateRequest,
    request: Request,
    db: Session = Depends(get_db),
    current_user: User = Depends(require_role(ADMIN)),
):
    """UC-A1 step 5: update account details or status, with the same rules
    as account creation. Alt 3a: unknown account -> 404. Alt 5a: invalid
    changes -> 422 (409 when the email / employee ID belongs to someone else)."""
    user = db.get(User, user_id)
    if user is None:
        raise HTTPException(status_code=404, detail="Account not found")  # UC-A1 3a
    changes = payload.model_dump(exclude_unset=True)
    card = changes.pop("employee_id_card", None)
    for key in ("first_name", "last_name", "email", "contact_number", "role_name", "is_active"):
        if key in changes and changes[key] is None:
            raise HTTPException(status_code=422, detail=f"{key.replace('_', ' ').capitalize()} cannot be empty")

    current_role = user.role.role_name if user.role else None
    is_self = user.user_id == current_user.user_id
    is_admin = current_role == ADMIN
    is_internal = current_role in INTERNAL_ROLES
    staff = is_internal or is_admin

    # --- self-protection and "never zero active Administrators" -----------
    if changes.get("is_active") is False:
        if is_self:
            raise HTTPException(status_code=400, detail="You cannot deactivate your own account")
        if is_admin and user.is_active and _active_admins(db) <= 1:
            raise HTTPException(status_code=400, detail="At least one active Administrator must remain")
    new_role = changes.get("role_name")
    if new_role is not None and new_role != current_role:
        if is_self:
            raise HTTPException(status_code=400, detail="You cannot change your own role")
        if is_admin:
            raise HTTPException(status_code=422, detail="Administrator accounts keep their role")
        if not is_internal:
            raise HTTPException(status_code=422,
                                detail="Only internal accounts can have their role changed")
    if not staff and ({"employee_id", "assigned_barangay_id"} & set(changes) or card):
        raise HTTPException(status_code=422,
                            detail="Employee ID, barangay and ID card are only for internal accounts")

    # --- final values, checked as a whole ---------------------------------
    final_role = new_role or current_role
    if final_role == BARANGAY_REP:
        final_brgy = changes.get("assigned_barangay_id", user.assigned_barangay_id)
        if final_brgy is None:
            raise HTTPException(status_code=422,
                                detail="Choose the assigned barangay for a Barangay Receiving Representative")
        _check_barangay(db, final_brgy)
    elif staff:
        if changes.get("assigned_barangay_id") is not None:
            raise HTTPException(status_code=422,
                                detail="Only a Barangay Receiving Representative has an assigned barangay")
        if user.assigned_barangay_id is not None:
            changes["assigned_barangay_id"] = None   # role changed away from barangay rep
    if final_role in INTERNAL_ROLES and set(changes) - {"is_active"}:
        # Required for internal accounts. Older accounts without one must get
        # it on their next edit; turning an account on/off alone is still allowed.
        if not changes.get("employee_id", user.employee_id):
            raise HTTPException(status_code=422, detail="Employee ID is required for internal accounts")
    if "email" in changes and _email_in_use(db, changes["email"], user.user_id):
        raise HTTPException(status_code=409, detail="Email already in use")
    if changes.get("employee_id") and _employee_id_in_use(db, changes["employee_id"], user.user_id):
        raise HTTPException(status_code=409, detail="Employee ID already in use")

    # --- apply ---------------------------------------------------------------
    old, new = {}, {}
    if new_role is not None and new_role != current_role:
        role = db.query(Role).filter(Role.role_name == new_role).first()
        if role is None:
            raise HTTPException(status_code=500, detail="Role configuration missing")
        old["role"], new["role"] = current_role, new_role
        user.role_id = role.role_id
    changes.pop("role_name", None)
    for k, v in changes.items():
        if getattr(user, k) != v:
            old[k], new[k] = getattr(user, k), v
            setattr(user, k, v)
    if card is not None:
        up = transfer_upload(db, card["file_id"], current_user, user, "employee_id_card")
        new["employee_id_card"] = up.file_id

    if new:
        action = "UPDATE ACCOUNT"
        if set(new) == {"is_active"}:
            action = "ACTIVATE ACCOUNT" if new["is_active"] else "DEACTIVATE ACCOUNT"
        log_action(db, current_user, action, "users", user.user_id, old=old, new=new, request=request)
    db.flush()
    db.refresh(user)
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
    background_tasks: BackgroundTasks,
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

    if payload.decision in ("Approved", "Rejected"):
        event = "org_approved" if payload.decision == "Approved" else "org_rejected"
        org_users = db.query(User.user_id, User.email).filter(
            User.organization_id == org.organization_id).all()
        for uid, _ in org_users:
            notify_event(db, uid, event, "organization", org.organization_id,
                         reason=payload.reason or "Please contact the administrator for details.")

        # Email the same decision to the organization (one message per address).
        recipients = {}
        for addr in [org.contact_email] + [email for _, email in org_users]:
            if addr:
                recipients.setdefault(addr.lower(), addr)
        greeting = org.contact_person or org.org_name
        if payload.decision == "Approved":
            subject = "Your NexaAid organization was approved"
            text = (f"Hello {greeting},\n\n"
                    f"Your organization, {org.org_name}, was approved. "
                    "You can now sign in to NexaAid and start donating.\n\nNexaAid")
        else:
            subject = "Your NexaAid organization registration was not approved"
            text = (f"Hello {greeting},\n\n"
                    f"Your registration for {org.org_name} was not approved.\n"
                    f"Reason: {payload.reason or 'Please contact the administrator for details.'}\n\n"
                    "NexaAid")
        for addr in recipients.values():
            _queue_email(background_tasks, addr, subject, text)
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