"""
api/v1/account_router.py — the logged-in user's own account (Ivan, I1).

I1 (Module 1.2): the Administrator creates internal accounts with a
temporary password, so users.must_change_password starts True. After
logging in, the app sends the user to Profile > Change password. This
endpoint saves the new password and clears the flag. Any role can use it.

Kept in its own file so it doesn't collide with auth_router.py
(registration, Dave) or session_router.py (login).
"""
from fastapi import APIRouter, BackgroundTasks, Depends, HTTPException, Request
from pydantic import BaseModel, Field
from sqlalchemy import func
from sqlalchemy.orm import Session

from core import email as mail_service
from core.audit import log_action
from core.auth import get_current_user, hash_password, verify_password
from core.database import get_db
from core.passwords import validate_password_strength
from core.temp_password import generate_temp_password
from models.user_rbac_model import User

router = APIRouter(prefix="/auth", tags=["account"])


class ChangePasswordRequest(BaseModel):
    current_password: str = Field(..., min_length=1, max_length=128)
    new_password: str = Field(..., min_length=1, max_length=64)
    confirm_password: str = Field(..., min_length=1, max_length=64)


@router.post("/change-password")
def change_password(
    payload: ChangePasswordRequest,
    request: Request,
    db: Session = Depends(get_db),
    user: User = Depends(get_current_user),
):
    # 400, not 401: a wrong current password must not log the app out.
    if not verify_password(payload.current_password, user.password_hash):
        raise HTTPException(status_code=400, detail="Current password is incorrect")
    if payload.new_password != payload.confirm_password:
        raise HTTPException(status_code=422, detail="Passwords do not match")
    if payload.new_password == payload.current_password:
        raise HTTPException(status_code=422, detail="Choose a new password, not the current one")
    try:
        # Same rule as registration (core/passwords.py, relaxed by Dave in D2).
        validate_password_strength(
            payload.new_password, email=user.email, names=(user.first_name, user.last_name)
        )
    except ValueError as e:
        raise HTTPException(status_code=422, detail=str(e))

    was_temporary = bool(user.must_change_password)
    user.password_hash = hash_password(payload.new_password)
    user.must_change_password = False
    # Never log the password or its hash.
    log_action(db, user, "CHANGE PASSWORD", "users", user.user_id,
               old={"must_change_password": was_temporary},
               new={"must_change_password": False}, request=request)
    db.flush()
    return {"detail": "Password changed", "must_change_password": False}


# ---------------------------------------------------------------------------
# Forgot password (login screen). No schema change: it reuses the temporary
# password flow of UC-A1 step 4. The server makes a new temporary password,
# emails it, and flags must_change_password, so the app sends the user to
# Change password right after they sign in with it.
# ---------------------------------------------------------------------------
FORGOT_REPLY = (
    "If that email belongs to a NexaAid account, a temporary password "
    "has been sent to it. Check your inbox and spam folder."
)


class ForgotPasswordRequest(BaseModel):
    email: str = Field(..., min_length=3, max_length=254)


@router.post("/forgot-password")
def forgot_password(
    payload: ForgotPasswordRequest,
    request: Request,
    background_tasks: BackgroundTasks,
    db: Session = Depends(get_db),
):
    if not mail_service.email_configured():
        raise HTTPException(
            status_code=503,
            detail="Email is not set up on the server, so a temporary password "
                   "cannot be sent. Ask the administrator for help.",
        )
    email = payload.email.strip().lower()
    user = db.query(User).filter(func.lower(User.email) == email).first()
    # Same reply whether or not the account exists, so emails can't be probed.
    # Deactivated accounts get nothing: they cannot sign in anyway.
    if user is None or not user.is_active:
        return {"detail": FORGOT_REPLY}

    temp_password = generate_temp_password()
    user.password_hash = hash_password(temp_password)
    user.must_change_password = True
    # Never log the password or its hash.
    log_action(db, user, "RESET PASSWORD", "users", user.user_id,
               new={"must_change_password": True}, request=request)
    db.flush()
    background_tasks.add_task(
        mail_service.send_email, user.email,
        "Your NexaAid temporary password",
        f"Hello {user.first_name},\n\n"
        "We received a request to reset your NexaAid password.\n\n"
        f"Temporary password: {temp_password}\n\n"
        "Sign in with it, then choose a new password right away. If you did "
        "not ask for this, sign in with the temporary password and change it.\n\n"
        "NexaAid",
    )
    return {"detail": FORGOT_REPLY}