# api/v1/admin_router.py
from datetime import datetime, timezone
from typing import Optional

from fastapi import APIRouter, BackgroundTasks, Depends, HTTPException, Query, Request, Response, status
from sqlalchemy import func, or_
from sqlalchemy.orm import Session
from core import email as mail_service
from core.database import get_db
from core.pagination import PageParams, paginate_list, paginate_query, set_total_header
from core.auth import hash_password, require_role
from core.temp_password import generate_temp_password
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
from services.accounts import delete_account
from pydantic import BaseModel, Field

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
    """UC-A1 step 4 (staff accounts only). Role and barangay rules are in the
    schema. The Administrator does not choose a password: the server makes a
    temporary one, stores only its hash, and emails it to the staff member,
    who must change it at first login (must_change_password)."""
    # Fail before anything is saved: without working email nobody would ever
    # learn the temporary password, and the account would be unusable.
    if not mail_service.email_configured():
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="Email is not set up on the server, so the temporary password "
                   "cannot be sent. Set BREVO_API_KEY and EMAIL_FROM.",
        )
    if payload.assigned_barangay_id is not None:
        _check_barangay(db, payload.assigned_barangay_id)
    if _email_in_use(db, payload.email):
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="Email already in use")
    if payload.employee_id and _employee_id_in_use(db, payload.employee_id):
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="Employee ID already in use")

    role = db.query(Role).filter(Role.role_name == payload.role_name).first()
    if role is None:
        raise HTTPException(status_code=status.HTTP_500_INTERNAL_SERVER_ERROR, detail="Role configuration missing")

    temp_password = generate_temp_password()

    new_user = User(
        first_name=payload.first_name, last_name=payload.last_name,
        email=payload.email, password_hash=hash_password(temp_password),
        contact_number=payload.contact_number, role_id=role.role_id,
        assigned_barangay_id=payload.assigned_barangay_id,
        must_change_password=True,
        employee_id=payload.employee_id,
    )
    db.add(new_user)
    db.flush()
    # The card was uploaded by this Administrator; the staff member owns it now.
    card = transfer_upload(db, payload.employee_id_card.file_id, current_user, new_user,
                           "employee_id_card")
    # The audit log never contains the password, only that the account was made.
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
        f"Temporary password: {temp_password}\n\n"
        "Sign in with this temporary password, then change it right away. "
        "Do not share it with anyone.\n\n"
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
        # Why and when an Administrator deactivated the account (None while
        # active, and for accounts deactivated before this was recorded).
        "deactivation_reason": u.deactivation_reason,
        "deactivated_at": u.deactivated_at,
        # Individual donors: the Administrator reviewed the registration.
        "reviewed_at": u.reviewed_at,
        "reviewed_by_user_id": u.reviewed_by_user_id,
        "created_at": u.created_at,
    }


# UC-A1 Manage Internal Accounts: list accounts, view role, update status/details
@router.get("/users")
def list_users(
    response: Response,
    role: Optional[str] = Query(default=None),
    q: Optional[str] = Query(default=None, description="search name or email"),
    active: Optional[bool] = Query(default=None, description="true = Active, false = Deactivated (I2)"),
    page: PageParams = Depends(),
    db: Session = Depends(get_db),
    current_user: User = Depends(require_role(ADMIN)),
):
    """NF-003: with `limit` (and `offset`) one page of 20 accounts, the
    total in X-Total-Count; without it the full list, as before."""
    # Deleted accounts (1.2) are gone from every section.
    query = db.query(User).join(Role, Role.role_id == User.role_id).filter(User.deleted_at.is_(None))
    if role:
        query = query.filter(Role.role_name == role)
    if q:
        like = f"%{q}%"
        query = query.filter(
            User.email.ilike(like) | User.first_name.ilike(like) | User.last_name.ilike(like)
        )
    orgs = {o.organization_id: o for o in db.query(Organization).all()}
    barangays = {b.barangay_id: b.barangay_name for b in db.query(Barangay).all()}
    if page.requested:
        # Paged: the status filter has to be in SQL so the count is right.
        if active is not None:
            # Postgres stores a real boolean; the SQLite test database keeps
            # the server default as the text 'true'. Both read alike here.
            is_on = or_(User.is_active == True, User.is_active == "true")  # noqa: E712
            query = query.filter(is_on if active else ~is_on)
        users, total = paginate_query(query, page, User.user_id)
        set_total_header(response, page, total)
        return [_user_row(u, orgs, barangays) for u in users]
    users = query.order_by(User.user_id).all()
    if active is not None:
        # I2. Filtered in Python so it reads is_active the same way on Postgres
        # and on the SQLite test database (like _active_admins below).
        users = [u for u in users if bool(u.is_active) == active]
    return [_user_row(u, orgs, barangays) for u in users]


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
    changes -> 422 (409 when the email / employee ID belongs to someone else).

    Deactivating an active account needs deactivation_reason (422 without
    it). The reason and the time are kept on the account and cleared when it
    is activated again."""
    user = db.get(User, user_id)
    if user is None or user.deleted_at is not None:
        raise HTTPException(status_code=404, detail="Account not found")  # UC-A1 3a
    changes = payload.model_dump(exclude_unset=True)
    card = changes.pop("employee_id_card", None)
    reason = changes.pop("deactivation_reason", None)   # already stripped; blank -> None
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
        if user.is_active and not reason:
            raise HTTPException(status_code=422, detail="Give a reason when you deactivate an account")
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
    if "is_active" in new:
        # Keep the reason with the account while it is deactivated; clear it
        # when the account is activated again.
        old["deactivation_reason"] = user.deactivation_reason
        if new["is_active"] is False:
            user.deactivation_reason = reason
            user.deactivated_at = datetime.now(timezone.utc)
        else:
            user.deactivation_reason = None
            user.deactivated_at = None
        new["deactivation_reason"] = user.deactivation_reason
    if card is not None:
        up = transfer_upload(db, card["file_id"], current_user, user, "employee_id_card")
        new["employee_id_card"] = up.file_id

    if new:
        action = "UPDATE ACCOUNT"
        if "is_active" in new and set(new) <= {"is_active", "deactivation_reason"}:
            action = "ACTIVATE ACCOUNT" if new["is_active"] else "DEACTIVATE ACCOUNT"
        log_action(db, current_user, action, "users", user.user_id, old=old, new=new, request=request)
    db.flush()
    db.refresh(user)
    orgs = {o.organization_id: o for o in db.query(Organization).all()}
    barangays = {b.barangay_id: b.barangay_name for b in db.query(Barangay).all()}
    return _user_row(user, orgs, barangays)


# Appendix H 1.2 (testing feedback, Oct 2026): delete a deactivated account.
# Anonymized, not removed: see services/accounts.py for why. Restore = the
# existing PATCH with is_active = true (the app's "Restore account" button).
@router.delete("/users/{user_id}")
def delete_user(
    user_id: int,
    request: Request,
    db: Session = Depends(get_db),
    current_user: User = Depends(require_role(ADMIN)),
):
    user = db.get(User, user_id)
    if user is None or user.deleted_at is not None:
        raise HTTPException(status_code=404, detail="Account not found")
    if user.user_id == current_user.user_id:
        raise HTTPException(status_code=400, detail="You cannot delete your own account")
    if user.is_active:
        # Two steps on purpose: deactivate (reversible) first, then delete.
        raise HTTPException(status_code=409, detail="Deactivate the account before deleting it")
    delete_account(db, user, current_user, request=request)
    return {"user_id": user.user_id, "deleted": True}


class RegistrationDelete(BaseModel):
    # e.g. "Fake ID", "Invalid document", "Fake ID: photo does not match".
    reason: str = Field(..., max_length=300)


# Registration review: donors and organizations sign in right after they
# register, so the Administrator checks the valid ID and documents
# afterwards. A fake ID or invalid document is removed in one step, with a
# required reason (kept in the audit log and emailed to the person). Staff
# accounts still use the two-step DELETE /admin/users/{id} above.
SELF_REGISTERED_ROLES = ("Individual Donor", "Relief Organization")


@router.post("/users/{user_id}/delete")
def delete_registration(
    user_id: int,
    payload: RegistrationDelete,
    request: Request,
    background_tasks: BackgroundTasks,
    db: Session = Depends(get_db),
    current_user: User = Depends(require_role(ADMIN)),
):
    reason = " ".join((payload.reason or "").split())
    if len(reason) < 3:
        raise HTTPException(status_code=422, detail="Give a reason when you delete an account")
    user = db.get(User, user_id)
    if user is None or user.deleted_at is not None:
        raise HTTPException(status_code=404, detail="Account not found")
    if user.user_id == current_user.user_id:
        raise HTTPException(status_code=400, detail="You cannot delete your own account")
    role = user.role.role_name if user.role else None
    if role not in SELF_REGISTERED_ROLES:
        raise HTTPException(
            status_code=400,
            detail="Only donor and organization registrations are deleted here. "
                   "Deactivate a staff account first, then delete it.")
    # Captured before the account is anonymized.
    to, first = user.email, user.first_name
    delete_account(db, user, current_user, request=request, reason=reason)
    _queue_email(
        background_tasks, to, "Your NexaAid account was removed",
        f"Hello {first},\n\nThe NexaAid Administrator removed your account after "
        f"reviewing your registration.\n\nReason: {reason}\n\nYou may register again "
        "with a valid ID and correct documents. If you think this is a mistake, "
        "contact the City Social Welfare Services office.\n\nNexaAid",
    )
    return {"user_id": user.user_id, "deleted": True, "reason": reason}


# UC-A2 Review Organization Registrations.
# Capstone 2 adviser comment 1.3: organizations are validated automatically
# when they register, so this list is for review only. There is no approve /
# hold / reject endpoint any more. To stop an organization, deactivate its
# account with PATCH /admin/users/{user_id} (is_active = false).
@router.get("/organizations")
def list_organizations(
    reviewed: Optional[bool] = Query(default=None),
    db: Session = Depends(get_db),
    current_user: User = Depends(require_role(ADMIN)),
):
    query = db.query(Organization)
    if reviewed is True:
        query = query.filter(Organization.reviewed_at.isnot(None))
    elif reviewed is False:
        query = query.filter(Organization.reviewed_at.is_(None))
    # NF-008 (D6): the review queue: Unverified first, Government first.
    return sorted(_organization_rows(db, query), key=review_order)


# ---------------------------------------------------------------------------
# NF-008 (D6, agreement A6): organization verification states.
#   Unverified   registered, not reviewed yet (can sign in and donate)
#   Verified     the Administrator reviewed it (organizations.reviewed_at);
#                a Verified badge shows to CSWS and on the dashboard
#   Deactivated  fake or wrong documents: the account is deactivated with a
#                reason, and the reason is emailed
# ---------------------------------------------------------------------------
UNVERIFIED, VERIFIED, DEACTIVATED = "Unverified", "Verified", "Deactivated"
GOVERNMENT_WARNING = "Government type – check document and ID"


def organization_state(org: Organization, account: Optional[User]) -> str:
    if account is not None and not account.is_active:
        return DEACTIVATED
    return VERIFIED if org.reviewed_at is not None else UNVERIFIED


def review_order(row: dict) -> tuple:
    """Unverified first, Government type first, then newest first."""
    state_rank = {UNVERIFIED: 0, VERIFIED: 1, DEACTIVATED: 2}.get(row.get("verification_state"), 1)
    gov_rank = 0 if row.get("organization_category") == "Government" else 1
    made = row.get("created_at")
    return (state_rank, gov_rank, -(made.timestamp() if made else 0), row["organization_id"])


def _organization_rows(db: Session, query) -> list:
    """The Registrations / organization rows for an Organization query,
    newest first."""
    # Reason and decision time kept in audit_logs from before comment 1.3,
    # when the Administrator still approved, held or rejected organizations.
    reasons, decided = {}, {}
    for log in (db.query(AuditLog)
                .filter(AuditLog.entity_type == "organizations",
                        AuditLog.action.in_(["HOLD ORGANIZATION", "REJECT ORGANIZATION",
                                             "APPROVE ORGANIZATION"]))
                .order_by(AuditLog.log_id)):
        reasons[log.entity_id] = (log.new_value or {}).get("reason")
        decided[log.entity_id] = log.timestamp
    # The organization's own account, for "View account" in Registrations.
    accounts, users = {}, {}
    for u in (db.query(User).filter(User.organization_id.isnot(None), User.deleted_at.is_(None))
              .order_by(User.user_id)):
        accounts.setdefault(u.organization_id, u.user_id)
        users.setdefault(u.organization_id, u)
    rows = []
    for o in query.order_by(Organization.created_at.desc()).all():
        account = users.get(o.organization_id)
        state = organization_state(o, account)
        category = o.organization_category or "Non-government"
        rows.append({
            "organization_id": o.organization_id,
            "org_name": o.org_name,
            "organization_type": o.organization_type,
            # NF-008 (D6): category, state and the review warning.
            "organization_category": category,
            "verification_state": state,
            "verified": state == VERIFIED,
            "warning": (GOVERNMENT_WARNING
                        if category == "Government" and state == UNVERIFIED else None),
            "contact_id_url": account.id_document_url if account else None,
            "deactivation_reason": (account.deactivation_reason
                                    if account is not None and not account.is_active else None),
            "address": o.address,
            "contact_person": o.contact_person,
            "contact_email": o.contact_email,
            "registration_no": o.registration_no,
            "legitimacy_document_url": o.legitimacy_document_url,
            # Comment 1.1: the document is optional, so this only means
            # "no document submitted". It is not an error.
            "document_missing": not (o.legitimacy_document_url or "").strip(),
            "contact_id_missing": not ((account.id_document_url if account else "") or "").strip(),
            "status": o.status,
            # Older rows only (organizations rejected before comment 1.3).
            "rejection_reason": o.rejection_reason,
            "decision_reason": o.rejection_reason or reasons.get(o.organization_id),
            "decided_at": decided.get(o.organization_id),
            "approved_at": o.approved_at,
            "reviewed_at": o.reviewed_at,
            "reviewed_by_user_id": o.reviewed_by_user_id,
            "created_at": o.created_at,
            "user_id": accounts.get(o.organization_id),
        })
    return rows


# Oct 11 notes (Jenises): the Administrator reviews individual donor
# registrations too, in the same Registrations list as organizations.
# Review only: donor accounts are active as soon as they register.
DONOR = "Individual Donor"


def _registrations(db: Session, review: str, kind: str, q: Optional[str]) -> list:
    """Organizations and individual donors as one list (Registrations),
    filtered by review status, kind and search, unsorted."""
    if review not in ("all", "done", "not"):
        raise HTTPException(status_code=422, detail="review must be all, done or not")
    if kind not in ("all", "donors", "orgs"):
        raise HTTPException(status_code=422, detail="kind must be all, donors or orgs")
    like = f"%{q.strip()}%" if q and q.strip() else None
    rows = []
    if kind in ("all", "orgs"):
        oq = db.query(Organization)
        if review == "done":
            oq = oq.filter(Organization.reviewed_at.isnot(None))
        elif review == "not":
            oq = oq.filter(Organization.reviewed_at.is_(None))
        if like:
            oq = oq.filter(Organization.org_name.ilike(like) | Organization.contact_email.ilike(like))
        for o in _organization_rows(db, oq):
            rows.append({
                "type": "org", "id": o["organization_id"], "name": o["org_name"],
                "email": o["contact_email"] or "No email", "created_at": o["created_at"],
                "reviewed": o["reviewed_at"] is not None, "org": o,
                # NF-008 (D6)
                "verification_state": o["verification_state"],
                "organization_category": o["organization_category"],
                "warning": o["warning"],
            })
    if kind in ("all", "donors"):
        uq = (db.query(User).join(Role, Role.role_id == User.role_id)
              .filter(Role.role_name == DONOR, User.deleted_at.is_(None)))
        if review == "done":
            uq = uq.filter(User.reviewed_at.isnot(None))
        elif review == "not":
            uq = uq.filter(User.reviewed_at.is_(None))
        if like:
            uq = uq.filter((User.first_name + " " + User.last_name).ilike(like) | User.email.ilike(like))
        for u in uq:
            rows.append({
                "type": "donor", "id": u.user_id, "name": f"{u.first_name} {u.last_name}".strip(),
                "email": u.email, "created_at": u.created_at, "reviewed": u.reviewed_at is not None,
            })
    return rows


@router.get("/registrations")
def list_registrations(
    response: Response,
    review: str = Query(default="all", description="all / done (Reviewed) / not (Not Reviewed)"),
    kind: str = Query(default="all", description="all / donors / orgs"),
    q: Optional[str] = Query(default=None, max_length=100, description="name or email"),
    sort: str = Query(default="newest",
                      description="newest / oldest / name / review (Unverified and Government first)"),
    focus_type: Optional[str] = Query(default=None, description="org / donor: only this registration"),
    focus_id: Optional[int] = Query(default=None),
    page: PageParams = Depends(),
    db: Session = Depends(get_db),
    current_user: User = Depends(require_role(ADMIN)),
):
    """NF-003: the Registrations list (organizations and individual donors),
    filtered, sorted and a page at a time on the server. It used to be built
    in the app from two full lists."""
    if sort not in ("newest", "oldest", "name", "review"):
        raise HTTPException(status_code=422, detail="sort must be newest, oldest, name or review")
    rows = _registrations(db, review, kind, q)
    if focus_type is not None and focus_id is not None:
        # The registration a notification is about (shown first, outlined).
        rows = [r for r in rows if r["type"] == focus_type and r["id"] == focus_id]

    def when(r):
        c = r["created_at"]
        return c.timestamp() if c is not None else None

    tie = lambda r: (r["type"], r["id"])  # noqa: E731  stable order for equal keys
    if sort == "review":
        # NF-008 (D6): not reviewed first; among them organizations, Government
        # type first; then newest.
        def queue(r):
            org = r.get("org") or {}
            return (r["reviewed"], r["type"] != "org",
                    org.get("organization_category") != "Government",
                    -(when(r) or 0), tie(r))
        rows.sort(key=queue)
    elif sort == "name":
        rows.sort(key=lambda r: (r["name"].lower(), tie(r)))
    else:
        dated = [r for r in rows if when(r) is not None]
        undated = sorted((r for r in rows if when(r) is None), key=tie)
        dated.sort(key=lambda r: (when(r), tie(r)), reverse=(sort == "newest"))
        rows = dated + undated  # unknown dates last, as in the app
    rows, total = paginate_list(rows, page)
    set_total_header(response, page, total)
    return rows


@router.get("/registrations/counts")
def registration_counts(
    db: Session = Depends(get_db),
    current_user: User = Depends(require_role(ADMIN)),
):
    """NF-003: All / Reviewed / Not Reviewed counts for the Registrations
    switch (over every registration, as before)."""
    rows = _registrations(db, "all", "all", None)
    reviewed = sum(1 for r in rows if r["reviewed"])
    return {"all": len(rows), "reviewed": reviewed, "not_reviewed": len(rows) - reviewed}


@router.patch("/users/{user_id}/review")
def review_donor(
    user_id: int,
    payload: dict,
    request: Request,
    db: Session = Depends(get_db),
    current_user: User = Depends(require_role(ADMIN)),
):
    """Mark an individual donor's registration Reviewed or Not Reviewed."""
    reviewed = payload.get("reviewed")
    if not isinstance(reviewed, bool):
        raise HTTPException(status_code=422, detail="'reviewed' must be true or false")
    user = db.get(User, user_id)
    if user is None or user.deleted_at is not None:
        raise HTTPException(status_code=404, detail="Account not found")
    if not user.role or user.role.role_name != DONOR:
        raise HTTPException(
            status_code=409,
            detail="Only individual donor registrations are reviewed here. "
                   "Organizations are reviewed in their own list.",
        )
    old = {"reviewed_at": user.reviewed_at.isoformat() if user.reviewed_at else None}
    if reviewed:
        user.reviewed_at = user.reviewed_at or datetime.now(timezone.utc)
        user.reviewed_by_user_id = user.reviewed_by_user_id or current_user.user_id
    else:
        user.reviewed_at = None
        user.reviewed_by_user_id = None
    new = {"reviewed_at": user.reviewed_at.isoformat() if user.reviewed_at else None}
    if old != new:
        log_action(db, current_user, "REVIEW DONOR", "users", user.user_id,
                   old=old, new=new, request=request)
    db.flush()
    return {
        "user_id": user.user_id,
        "reviewed_at": user.reviewed_at,
        "reviewed_by_user_id": user.reviewed_by_user_id,
    }


@router.patch("/organizations/{organization_id}/review")
def review_organization(
    organization_id: int,
    payload: dict,
    request: Request,
    db: Session = Depends(get_db),
    current_user: User = Depends(require_role(ADMIN)),
):
    """Mark an organization Reviewed or Not Reviewed without changing activation."""
    reviewed = payload.get("reviewed")
    if not isinstance(reviewed, bool):
        raise HTTPException(
            status_code=422,
            detail="'reviewed' must be true or false",
        )

    org = db.get(Organization, organization_id)
    if org is None:
        raise HTTPException(status_code=404, detail="Organization not found")

    old = {
        "reviewed_at": org.reviewed_at.isoformat() if org.reviewed_at else None,
        "reviewed_by_user_id": org.reviewed_by_user_id,
    }

    if reviewed:
        org.reviewed_at = datetime.now(timezone.utc)
        org.reviewed_by_user_id = current_user.user_id
    else:
        org.reviewed_at = None
        org.reviewed_by_user_id = None

    new = {
        "reviewed_at": org.reviewed_at.isoformat() if org.reviewed_at else None,
        "reviewed_by_user_id": org.reviewed_by_user_id,
    }

    if old != new:
        log_action(
            db, current_user, "REVIEW ORGANIZATION", "organizations",
            org.organization_id, old=old, new=new, request=request,
        )

    db.flush()
    db.refresh(org)
    return {
        "organization_id": org.organization_id,
        "org_name": org.org_name,
        "status": org.status,
        "reviewed_at": org.reviewed_at,
        "reviewed_by_user_id": org.reviewed_by_user_id,
    }


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


class OrganizationDeactivate(BaseModel):
    reason: str = Field(..., max_length=500)


def _org_or_404(db: Session, organization_id: int) -> Organization:
    org = db.get(Organization, organization_id)
    if org is None:
        raise HTTPException(status_code=404, detail="Organization not found")
    return org


def _org_view(db: Session, org: Organization) -> dict:
    return next(r for r in _organization_rows(
        db, db.query(Organization).filter(Organization.organization_id == org.organization_id)))


@router.post("/organizations/{organization_id}/verify")
def verify_organization(
    organization_id: int,
    request: Request,
    db: Session = Depends(get_db),
    current_user: User = Depends(require_role(ADMIN)),
):
    """NF-008 (D6) Mark verified: sets organizations.reviewed_at, so the
    Verified badge shows to CSWS and on the transparency dashboard."""
    org = _org_or_404(db, organization_id)
    if org.reviewed_at is None:
        org.reviewed_at = datetime.now(timezone.utc)
        org.reviewed_by_user_id = current_user.user_id
        log_action(db, current_user, "VERIFY ORGANIZATION", "organizations", org.organization_id,
                   old={"verification_state": UNVERIFIED},
                   new={"verification_state": VERIFIED, "reviewed_at": org.reviewed_at.isoformat()},
                   request=request)
    db.flush()
    return _org_view(db, org)


@router.post("/organizations/{organization_id}/deactivate")
def deactivate_organization(
    organization_id: int,
    payload: OrganizationDeactivate,
    request: Request,
    background_tasks: BackgroundTasks,
    db: Session = Depends(get_db),
    current_user: User = Depends(require_role(ADMIN)),
):
    """NF-008 (D6) Deactivate (fake or wrong documents): a reason is
    required; every account of the organization is deactivated with it and
    the reason is emailed to the organization. Activate it again with
    PATCH /admin/users/{user_id} (is_active = true)."""
    reason = (payload.reason or "").strip()
    if len(reason) < 5:
        raise HTTPException(status_code=422,
                            detail="Give a reason when you deactivate an organization")
    org = _org_or_404(db, organization_id)
    accounts = (db.query(User)
                .filter(User.organization_id == org.organization_id, User.deleted_at.is_(None))
                .all())
    if any(u.user_id == current_user.user_id for u in accounts):
        raise HTTPException(status_code=400, detail="You cannot deactivate your own account")
    now = datetime.now(timezone.utc)
    for u in accounts:
        u.is_active = False
        u.deactivation_reason = reason
        u.deactivated_at = now
    log_action(db, current_user, "DEACTIVATE ORGANIZATION", "organizations", org.organization_id,
               new={"verification_state": DEACTIVATED, "reason": reason,
                    "accounts": [u.user_id for u in accounts]},
               request=request)
    to = {org.contact_email} | {u.email for u in accounts if u.email}
    for address in sorted(a for a in to if a):
        _queue_email(
            background_tasks, address, "Your NexaAid organization account was deactivated",
            f"Hello,\n\nThe NexaAid account of {org.org_name} was deactivated by the "
            f"Administrator.\n\nReason: {reason}\n\nIf you think this is a mistake, contact "
            "the City Social Welfare Services office.\n\nNexaAid",
        )
    db.flush()
    return _org_view(db, org)
