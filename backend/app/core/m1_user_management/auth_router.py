# routers/auth_router.py
import hashlib
import hmac
import secrets
from datetime import datetime, timedelta, timezone

from fastapi import APIRouter, BackgroundTasks, Depends, HTTPException, Request, status
from sqlalchemy import func
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from core.shared.audit import log_action
from core.m1_user_management.auth import get_current_user, hash_password
from core.shared.config import settings
from core.shared.database import get_db
from core.shared.email import send_email
from core.shared.uploads import claim_registration_files, file_url
from core.m1_user_management.user_rbac_model import User
from core.m1_user_management.role_model import Role
from core.m1_user_management.organization_model import Organization
from core.m1_user_management.password_reset_model import PasswordResetToken
from core.m1_user_management.email_verification_model import EmailVerificationCode
from pydantic import BaseModel, Field
from core.m1_user_management.user_schema import (
    DonorRegisterRequest, ForgotPasswordRequest, ResetPasswordRequest, UserResponse,
)
from core.m1_user_management.organization_schema import OrganizationRegisterRequest, OrganizationResponse
from core.notifications.notifications import notify_event, notify_event_many, user_ids_with_role

router = APIRouter(prefix="/auth", tags=["auth"])

RESET_CODE_MINUTES = 15
MAX_RESET_ATTEMPTS = 5

# The two register endpoints commit before they answer, because the app signs
# the new account in right after registering and get_db() would only commit
# after the response and the email task. Everything is still saved in one
# commit at the end, so when an uploaded file can't be claimed (expired,
# wrong token, wrong purpose), the account is not created either: the error
# is raised first and get_db rolls everything back.


def _email_taken(db: Session, email: str) -> bool:
    return db.query(User).filter(func.lower(User.email) == email.lower()).first() is not None


def _username_taken(db: Session, username: str) -> bool:
    # Usernames are saved in lowercase (core/m1_user_management/usernames.py), and the schema
    # already lowercased this one.
    return db.query(User).filter(User.username == username.lower()).first() is not None


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
    validated automatically (Capstone 2 adviser comment 1.3) and the app
    signs it in right after registering. The Administrator is notified and
    may review the ID afterwards."""
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
        address=payload.address,
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
    # Commit before answering: the app signs in right after registering, and
    # get_db() would only commit after the response and the email task.
    db.commit()
    db.refresh(new_user)
    return new_user


@router.post("/register/organization", response_model=OrganizationResponse, status_code=status.HTTP_201_CREATED)
def register_organization(
    payload: OrganizationRegisterRequest,
    request: Request,
    background_tasks: BackgroundTasks,
    db: Session = Depends(get_db),
):
    """UC-A2: the organization registers and does not wait for the
    Administrator: the app signs it in right after registering and it goes
    straight to its dashboard (comment 1.3, team decision F). NF-008 (D6):
    it starts Unverified until the Administrator reviews it; the contact
    person's government ID is required for every type, and Government types
    also need one supporting document (optional for the others, comment
    1.1). The registration form no longer asks for a registration number;
    the field is still accepted here and stored as NULL when missing."""
    if _email_taken(db, payload.contact_email):
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="Email already registered")
    # The organization's login name. Optional for the API, required by the app.
    if payload.username and _username_taken(db, payload.username):
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="Username already taken")
    # Only check for duplicates when a number was given. The app no longer
    # sends one, so normally this is skipped (the value is stored as NULL).
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
        organization_category=payload.category,
        address=payload.address,
        contact_person=payload.contact_person,
        registration_no=payload.registration_no,
        contact_email=payload.contact_email,
        # Organizations activate automatically; administrator review is separate.
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
        username=payload.username,
        id_type=payload.id_type,
        role_id=org_role.role_id,
        organization_id=new_org.organization_id,
        terms_accepted_at=datetime.now(timezone.utc),
    )
    db.add(new_user)
    # Two people taking the same email or username at the same moment end up
    # here, so the message names both.
    _flush_or_409(db, "Email or username already registered")

    # NF-008: the contact person's government ID, like an individual donor
    # (the back is found later through the uploads table). The supporting
    # document: required for Government types (the schema checks), optional
    # for the others (adviser comment 1.1: e.g. churches have none).
    refs = {"id_front": payload.id_front, "id_back": payload.id_back}
    if payload.legitimacy_document is not None:
        refs["legitimacy_document"] = payload.legitimacy_document
    files = claim_registration_files(db, new_user, refs)
    new_user.id_document_url = file_url(files["id_front"].file_id)
    if "legitimacy_document" in files:
        new_org.legitimacy_document_url = file_url(files["legitimacy_document"].file_id)

    log_action(db, new_user, "REGISTER ORGANIZATION", "organizations", new_org.organization_id, new={
        "org_name": new_org.org_name,
        "organization_type": new_org.organization_type,
        "organization_category": new_org.organization_category,
        "email": new_user.email,
        "consent_ra10173": True,
    }, request=request)

    notify_event_many(db, user_ids_with_role(db, ["Administrator"]),
                      "org_registered", "organization", new_org.organization_id,
                      name=new_org.org_name)

    # Registration confirmation email (never includes the password).
    # authenticate_user() lets the organization sign in right away because
    # its status is already Approved.
    # The organization can sign in with its username or this email address.
    login_hint = (
        f"your username ({new_user.username}) or this email address"
        if new_user.username else "this email address"
    )
    background_tasks.add_task(
        send_email, new_user.email, "Welcome to NexaAid",
        f"Hello {new_user.first_name},\n\n"
        f"Your organization, {new_org.org_name}, was registered and is active. "
        f"You can now sign in with {login_hint}.\n\nNexaAid",
    )
    # Commit before answering (see register_donor): the app signs in at once.
    db.commit()
    db.refresh(new_org)
    return new_org


# ---------------------------------------------------------------------------
# Forgot password (adviser comment: login page). A 6-digit code is emailed,
# expires after RESET_CODE_MINUTES, works once, and allows MAX_RESET_ATTEMPTS
# wrong guesses. Codes are stored hashed.
# F-03: forgot-password answers the same for every email, so it cannot be
# used to check who has an account. F-02: per account, at most
# MAX_CODES_PER_HOUR codes and MAX_WRONG_CODES_PER_HOUR wrong guesses an
# hour (counted from password_reset_tokens, no migration).
# ---------------------------------------------------------------------------

MAX_CODES_PER_HOUR = 5
MAX_WRONG_CODES_PER_HOUR = 10
RESET_REPLY = {"detail": "If that email has an active account, a reset code was sent."}


def _code_hash(code: str) -> str:
    return hmac.new(settings.SECRET_KEY.encode(), code.encode(), hashlib.sha256).hexdigest()


def _last_hour(db: Session, user_id: int):
    """This account's reset codes created in the last hour."""
    since = datetime.now(timezone.utc) - timedelta(hours=1)
    return db.query(PasswordResetToken).filter(
        PasswordResetToken.user_id == user_id,
        PasswordResetToken.created_at > since,
    )


@router.post("/forgot-password")
def forgot_password(
    payload: ForgotPasswordRequest,
    background_tasks: BackgroundTasks,
    db: Session = Depends(get_db),
):
    user = db.query(User).filter(func.lower(User.email) == payload.email.lower()).first()
    # Unknown, deactivated or already sent enough codes this hour: the same
    # answer, and no email.
    if (user is None or not user.is_active
            or _last_hour(db, user.user_id).count() >= MAX_CODES_PER_HOUR):
        return RESET_REPLY
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
    return RESET_REPLY


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
    # F-02: wrong guesses are counted per account, over every code of the
    # last hour, so asking for new codes does not give new guesses.
    wrong = (_last_hour(db, user.user_id)
             .with_entities(func.coalesce(func.sum(PasswordResetToken.attempts), 0))
             .scalar())
    if wrong >= MAX_WRONG_CODES_PER_HOUR:
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


# ---------------------------------------------------------------------------
# NF-006 (D4): verify the account email once (agreement A4).
# Same pattern as forgot password: a 6-digit code, stored hashed
# (_code_hash), valid VERIFY_CODE_MINUTES, MAX_VERIFY_ATTEMPTS wrong tries,
# at most MAX_VERIFY_CODES_PER_HOUR codes an hour. Registration still signs
# in at once; only Door to Door pickups wait for it (core/m4_donation_management/email_hold.py).
# ---------------------------------------------------------------------------
VERIFY_CODE_MINUTES = 15
MAX_VERIFY_ATTEMPTS = 5
MAX_VERIFY_CODES_PER_HOUR = 5


class VerifyEmailConfirm(BaseModel):
    code: str = Field(..., min_length=6, max_length=6, pattern=r"^\d{6}$")


def _verified_reply(user: User) -> dict:
    return {"detail": "Your email is verified.", "email_verified": True,
            "email_verified_at": user.email_verified_at.isoformat() if user.email_verified_at else None}


def _verify_codes_last_hour(db: Session, user_id: int):
    since = datetime.now(timezone.utc) - timedelta(hours=1)
    return db.query(EmailVerificationCode).filter(
        EmailVerificationCode.user_id == user_id,
        EmailVerificationCode.created_at > since,
    )


@router.post("/verify-email/send")
def send_email_verification(
    background_tasks: BackgroundTasks,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    """Email a 6-digit code to the signed-in account's own address."""
    if current_user.email_verified_at is not None:
        return _verified_reply(current_user)
    if _verify_codes_last_hour(db, current_user.user_id).count() >= MAX_VERIFY_CODES_PER_HOUR:
        raise HTTPException(
            status_code=status.HTTP_429_TOO_MANY_REQUESTS,
            detail="Too many codes this hour. Use the last code we sent, or try again later.",
        )
    now = datetime.now(timezone.utc)
    # Only the newest code works.
    db.query(EmailVerificationCode).filter(
        EmailVerificationCode.user_id == current_user.user_id,
        EmailVerificationCode.used_at.is_(None),
    ).update({"used_at": now})
    code = f"{secrets.randbelow(1_000_000):06d}"
    db.add(EmailVerificationCode(
        user_id=current_user.user_id,
        code_hash=_code_hash(code),
        expires_at=now + timedelta(minutes=VERIFY_CODE_MINUTES),
    ))
    background_tasks.add_task(
        send_email, current_user.email, "Your NexaAid email verification code",
        f"Hello {current_user.first_name},\n\n"
        f"Your NexaAid verification code is {code}. It expires in {VERIFY_CODE_MINUTES} minutes.\n\n"
        "Enter it in the app to confirm your email. You only do this once; after that "
        "CSWS can pick up your Door to Door donations.\n\n"
        "If you did not ask for this, you can ignore this email.\n\nNexaAid",
    )
    db.commit()
    return {"detail": f"We sent a 6-digit code to {current_user.email}.",
            "email_verified": False, "expires_in_minutes": VERIFY_CODE_MINUTES}


@router.post("/verify-email/confirm")
def confirm_email_verification(
    payload: VerifyEmailConfirm,
    request: Request,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    """Check the code. Once it matches, the account is verified for good and
    every Door to Door donation still waiting goes to the CSWS pickup map,
    with its handover deadline counted from now."""
    if current_user.email_verified_at is not None:
        return {**_verified_reply(current_user), "released": []}
    token = (
        db.query(EmailVerificationCode)
        .filter(EmailVerificationCode.user_id == current_user.user_id,
                EmailVerificationCode.used_at.is_(None))
        .order_by(EmailVerificationCode.created_at.desc(), EmailVerificationCode.code_id.desc())
        .first()
    )
    if token is None:
        raise HTTPException(status_code=400, detail="No code is waiting. Ask for a new code.")
    if token.attempts >= MAX_VERIFY_ATTEMPTS:
        raise HTTPException(status_code=status.HTTP_429_TOO_MANY_REQUESTS,
                            detail="Too many wrong codes. Ask for a new code.")
    now = datetime.now(timezone.utc)
    expires = token.expires_at
    if expires.tzinfo is None:  # SQLite (tests) returns naive datetimes
        expires = expires.replace(tzinfo=timezone.utc)
    if expires < now:
        raise HTTPException(status_code=400, detail="This code expired. Ask for a new code.")
    if not hmac.compare_digest(token.code_hash, _code_hash(payload.code)):
        token.attempts += 1
        db.commit()  # get_db rolls back when an error is raised, so save the wrong guess first
        if token.attempts >= MAX_VERIFY_ATTEMPTS:
            raise HTTPException(status_code=status.HTTP_429_TOO_MANY_REQUESTS,
                                detail="Too many wrong codes. Ask for a new code.")
        left = MAX_VERIFY_ATTEMPTS - token.attempts
        raise HTTPException(status_code=400,
                            detail=f"Wrong code. {left} tr{'ies' if left != 1 else 'y'} left.")

    from core.m4_donation_management.email_hold import release_holds
    token.used_at = now
    current_user.email_verified_at = now
    released = release_holds(db, current_user)
    log_action(db, current_user, "VERIFY EMAIL", "users", current_user.user_id,
               new={"email_verified_at": now.isoformat(), "pickups_released": released},
               request=request)
    db.commit()
    db.refresh(current_user)
    return {**_verified_reply(current_user), "released": released}
