# api/v1/auth_router.py
import hashlib
import hmac
import secrets
from datetime import datetime, timedelta, timezone

from fastapi import APIRouter, BackgroundTasks, Depends, HTTPException, Request, status
from sqlalchemy import func
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from core.audit import log_action
from core.auth import hash_password
from core.config import settings
from core.database import get_db
from core.email import send_email
from core.notifications import notify_event, notify_event_many, user_ids_with_role
from core.uploads import claim_registration_files, file_url
from models.organization_model import Organization
from models.password_reset_model import PasswordResetToken
from models.role_model import Role
from models.user_rbac_model import User
from schemas.organization_schema import OrganizationRegisterRequest, OrganizationResponse
from schemas.user_schema import (
    DonorRegisterRequest, ForgotPasswordRequest, ResetPasswordRequest, UserResponse,
)

router = APIRouter(prefix="/auth", tags=["auth"])

# The register endpoints never call db.commit() themselves: get_db commits
# once at the end, and rolls back if anything raised. So when an uploaded
# file can't be claimed (expired, wrong token, wrong purpose), the account is
# not created either.

RESET_CODE_MINUTES = 15
MAX_RESET_ATTEMPTS = 5


def _email_taken(db: Session, email: str) -> bool:
    return db.query(User).filter(func.lower(User.email) == email.lower()).first() is not None


def _flush_or_409(db: Session, detail: str) -> None:
    # Two people registering the same email at the same moment: the second
    # one hits the UNIQUE constraint here instead of a 500.
    try:
        db.flush()
    except IntegrityError:
        db.rollback()
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail=detail)


@router.post("/register/donor", response_model=UserResponse, status_code=status.HTTP_201_CREATED)
def register_donor(
    payload: DonorRegisterRequest,
    request: Request,
    background_tasks: BackgroundTasks,
    db: Session = Depends(get_db),
):
    """UC-D1 Register Individual Donor (adviser item 2). The account is
    validated automatically (Capstone 2 adviser comment 1.3); the
    Administrator is notified and may review the ID afterwards."""
    if _email_taken(db, payload.email):
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="Email already registered")

    donor_role = db.query(Role).filter(Role.role_name == "Individual Donor").first()
    if donor_role is None:
        raise HTTPException(status_code=status.HTTP_500_INTERNAL_SERVER_ERROR, detail="Role configuration missing")

    new_user = User(
        first_name=payload.first_name,
        last_name=payload.last_name,
        email=payload.email,
        password_hash=hash_password(payload.password),
        contact_number=payload.contact_number,
        id_type=payload.id_type,
        role_id=donor_role.role_id,
        organization_id=None,
        terms_accepted_at=datetime.now(timezone.utc),
    )
    db.add(new_user)
    _flush_or_409(db, "Email already registered")

    # UC-D1 step 3: attach the ID photos uploaded before the account existed.
    files = claim_registration_files(db, new_user, {
        "id_front": payload.id_front,
        "id_back": payload.id_back,
    })
    # The back is found later through the uploads table (owner + purpose).
    new_user.id_document_url = file_url(files["id_front"].file_id)

    log_action(db, new_user, "REGISTER DONOR", "users", new_user.user_id, new={
        "email": new_user.email,
        "id_type": new_user.id_type,
        "consent_ra10173": True,
    }, request=request)

    # Adviser comment 1.1: the Administrator is told about every new donor.
    notify_event_many(db, user_ids_with_role(db, ["Administrator"]),
                      "donor_registered", "user", new_user.user_id,
                      name=f"{new_user.first_name} {new_user.last_name}")

    # Registration confirmation email (never includes the password).
    background_tasks.add_task(
        send_email, new_user.email, "Welcome to NexaAid",
        f"Hello {new_user.first_name},\n\n"
        "Your NexaAid donor account was created. You can now sign in "
        "with this email address.\n\nNexaAid",
    )
    db.flush()
    db.refresh(new_user)
    return new_user


@router.post("/register/organization", response_model=OrganizationResponse, status_code=status.HTTP_201_CREATED)
def register_organization(
    payload: OrganizationRegisterRequest,
    request: Request,
    background_tasks: BackgroundTasks,
    db: Session = Depends(get_db),
):
    """UC-A2: the organization registers and is validated automatically
    (Capstone 2 adviser comment 1.3). The supporting document is optional
    (comment 1.1); the Administrator reviews the registration afterwards."""
    if _email_taken(db, payload.contact_email):
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="Email already registered")
    # Only check for duplicates when a number was given. Religious and Other
    # organizations may leave it blank (stored as NULL).
    if payload.registration_no and db.query(Organization).filter(
        Organization.registration_no == payload.registration_no
    ).first():
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="Registration number already used")

    org_role = db.query(Role).filter(Role.role_name == "Relief Organization").first()
    if org_role is None:
        raise HTTPException(status_code=status.HTTP_500_INTERNAL_SERVER_ERROR, detail="Role configuration missing")

    new_org = Organization(
        org_name=payload.org_name,
        organization_type=payload.organization_type_label,
        address=payload.address,
        contact_person=payload.contact_person,
        registration_no=payload.registration_no,
        contact_email=payload.contact_email,
        # Adviser comment 1.3: validated automatically, no admin approval.
        status="Approved",
        approved_at=datetime.now(timezone.utc),
    )
    db.add(new_org)
    _flush_or_409(db, "Email or registration number already exists")

    new_user = User(
        first_name=payload.contact_first_name,
        last_name=payload.contact_last_name,
        email=payload.contact_email,
        password_hash=hash_password(payload.password),
        contact_number=payload.contact_number,
        role_id=org_role.role_id,
        organization_id=new_org.organization_id,
        terms_accepted_at=datetime.now(timezone.utc),
    )
    db.add(new_user)
    _flush_or_409(db, "Email already registered")

    # Adviser comment 1.1: the supporting document is optional. Some
    # organization types (e.g. churches) have no documents.
    if payload.legitimacy_document is not None:
        files = claim_registration_files(db, new_user, {
            "legitimacy_document": payload.legitimacy_document,
        })
        new_org.legitimacy_document_url = file_url(files["legitimacy_document"].file_id)

    log_action(db, new_user, "REGISTER ORGANIZATION", "organizations", new_org.organization_id, new={
        "org_name": new_org.org_name,
        "email": new_user.email,
        "consent_ra10173": True,
    }, request=request)

    notify_event_many(db, user_ids_with_role(db, ["Administrator"]),
                      "org_registered", "organization", new_org.organization_id,
                      name=new_org.org_name)

    # Registration confirmation email (never includes the password).
    # authenticate_user() lets the organization sign in right away because
    # its status is already Approved.
    background_tasks.add_task(
        send_email, new_user.email, "Welcome to NexaAid",
        f"Hello {new_user.first_name},\n\n"
        f"Your organization, {new_org.org_name}, was registered and is active. "
        "You can now sign in with this email address.\n\nNexaAid",
    )
    db.flush()
    db.refresh(new_org)
    return new_org


# ---------------------------------------------------------------------------
# Forgot password (adviser comment: login page). A 6-digit code is emailed,
# expires after RESET_CODE_MINUTES, works once, and allows MAX_RESET_ATTEMPTS
# wrong guesses. Codes are stored hashed.
# ---------------------------------------------------------------------------

def _code_hash(code: str) -> str:
    return hmac.new(settings.SECRET_KEY.encode(), code.encode(), hashlib.sha256).hexdigest()


@router.post("/forgot-password")
def forgot_password(
    payload: ForgotPasswordRequest,
    background_tasks: BackgroundTasks,
    db: Session = Depends(get_db),
):
    user = db.query(User).filter(func.lower(User.email) == payload.email.lower()).first()
    if user is not None and user.is_active:
        now = datetime.now(timezone.utc)
        # Only the newest code works.
        db.query(PasswordResetToken).filter(
            PasswordResetToken.user_id == user.user_id,
            PasswordResetToken.used_at.is_(None),
        ).update({"used_at": now})
        code = f"{secrets.randbelow(1_000_000):06d}"
        db.add(PasswordResetToken(
            user_id=user.user_id,
            code_hash=_code_hash(code),
            expires_at=now + timedelta(minutes=RESET_CODE_MINUTES),
        ))
        background_tasks.add_task(
            send_email, user.email, "Your NexaAid password reset code",
            f"Hello {user.first_name},\n\n"
            f"Your password reset code is {code}. It expires in {RESET_CODE_MINUTES} minutes.\n\n"
            "If you did not ask for this, you can ignore this email.\n\nNexaAid",
        )
    # Same answer whether or not the email exists, so emails can't be probed.
    return {"detail": "If that email is registered, a reset code was sent."}


@router.post("/reset-password")
def reset_password(
    payload: ResetPasswordRequest,
    request: Request,
    db: Session = Depends(get_db),
):
    bad = HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="Invalid or expired code")
    user = db.query(User).filter(func.lower(User.email) == payload.email.lower()).first()
    if user is None or not user.is_active:
        raise bad

    token = (
        db.query(PasswordResetToken)
        .filter(PasswordResetToken.user_id == user.user_id, PasswordResetToken.used_at.is_(None))
        .order_by(PasswordResetToken.created_at.desc())
        .first()
    )
    if token is None or token.attempts >= MAX_RESET_ATTEMPTS:
        raise bad

    now = datetime.now(timezone.utc)
    expires = token.expires_at
    if expires.tzinfo is None:  # SQLite (tests) returns naive datetimes
        expires = expires.replace(tzinfo=timezone.utc)
    if expires < now:
        raise bad

    if not hmac.compare_digest(token.code_hash, _code_hash(payload.code)):
        token.attempts += 1
        db.commit()  # get_db rolls back when an error is raised, so save the wrong guess first
        raise bad

    user.password_hash = hash_password(payload.new_password)
    user.must_change_password = False
    token.used_at = now
    log_action(db, user, "RESET PASSWORD", "users", user.user_id,
               new={"method": "email code"}, request=request)
    notify_event(db, user.user_id, "account_password_changed", "user", user.user_id)
    db.flush()
    return {"detail": "Password updated. You can now log in."}