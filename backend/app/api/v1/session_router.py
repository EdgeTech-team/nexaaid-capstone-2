from fastapi import APIRouter, Depends, HTTPException
from fastapi.security import OAuth2PasswordRequestForm
from sqlalchemy.orm import Session

from core.database import get_db
from core.auth import (
    authenticate_user, build_login_response, get_current_user_allow_temp,
    user_payload, verify_password, hash_password,
)
from core.passwords import validate_password_strength
from models.user_rbac_model import User
from schemas.user_schema import LoginRequest, ChangePasswordRequest

router = APIRouter(tags=["session"])


@router.post("/token")  # form-data; this is what Swagger's Authorize button uses
def token_for_swagger(form_data: OAuth2PasswordRequestForm = Depends(), db: Session = Depends(get_db)):
    return build_login_response(authenticate_user(db, form_data.username, form_data.password))


@router.post("/auth/login")  # JSON; this is what Flutter calls
def login(payload: LoginRequest, db: Session = Depends(get_db)):
    return build_login_response(authenticate_user(db, payload.email, payload.password))


@router.get("/auth/me")  # Flutter calls this on app start to restore the session
def me(user: User = Depends(get_current_user_allow_temp)):
    return user_payload(user)


@router.post("/auth/change-password")  # must work while must_change_password is true
def change_password(
    payload: ChangePasswordRequest,
    db: Session = Depends(get_db),
    user: User = Depends(get_current_user_allow_temp),
):
    if not verify_password(payload.current_password, user.password_hash):
        raise HTTPException(status_code=400, detail="Current password is incorrect")
    if payload.current_password == payload.new_password:
        raise HTTPException(status_code=400, detail="New password must be different from the current one")
    try:
        validate_password_strength(payload.new_password, email=user.email, names=(user.first_name, user.last_name))
    except ValueError as e:
        raise HTTPException(status_code=422, detail=str(e))

    user.password_hash = hash_password(payload.new_password)
    user.must_change_password = False
    db.commit()
    return {"message": "Password updated"}