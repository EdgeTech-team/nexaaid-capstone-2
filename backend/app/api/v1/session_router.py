from fastapi import APIRouter, Depends
from fastapi.security import OAuth2PasswordRequestForm
from sqlalchemy.orm import Session

from core.database import get_db
from core.auth import authenticate_user, build_login_response, get_current_user, user_payload
from models.user_rbac_model import User
from schemas.user_schema import LoginRequest

router = APIRouter(tags=["session"])


@router.post("/token")  # form-data; this is what Swagger's Authorize button uses
def token_for_swagger(form_data: OAuth2PasswordRequestForm = Depends(), db: Session = Depends(get_db)):
    return build_login_response(authenticate_user(db, form_data.username, form_data.password))


@router.post("/auth/login")  # JSON; this is what Flutter calls
def login(payload: LoginRequest, db: Session = Depends(get_db)):
    return build_login_response(authenticate_user(db, payload.email, payload.password))


@router.get("/auth/me")  # Flutter calls this on app start to restore the session
def me(user: User = Depends(get_current_user)):
    return user_payload(user)