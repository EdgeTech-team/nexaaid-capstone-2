"""
api/v1/account_router.py — the logged-in user's own account (Ivan, I1).

I1 (Module 1.2): the Administrator creates internal accounts with a
temporary password, so users.must_change_password starts True. After
logging in, the app sends the user to Profile > Change password. This
endpoint saves the new password and clears the flag. Any role can use it.

Kept in its own file so it doesn't collide with auth_router.py
(registration, Dave) or session_router.py (login).
"""
from fastapi import APIRouter, Depends, HTTPException, Request
from pydantic import BaseModel, Field
from sqlalchemy.orm import Session

from core.audit import log_action
from core.auth import get_current_user, hash_password, verify_password
from core.database import get_db
from core.passwords import validate_password_strength
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