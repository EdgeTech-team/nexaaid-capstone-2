from datetime import datetime, timedelta, timezone

from fastapi import APIRouter, BackgroundTasks, Depends
from fastapi.security import OAuth2PasswordRequestForm
from sqlalchemy.orm import Session

from core import email as mail_service
from core.database import get_db
from core.auth import authenticate_user, build_login_response, get_current_user, user_payload
from models.user_rbac_model import User
from schemas.user_schema import LoginRequest

router = APIRouter(tags=["session"])

# Only self-registered users get a sign-in notice. Staff accounts keep their
# existing temporary-password email from admin_router and get nothing here.
NOTIFY_ON_LOGIN = ("Individual Donor", "Relief Organization")
PH_TIME = timezone(timedelta(hours=8))  # Cebu City


def _queue_login_notice(background_tasks: BackgroundTasks, user: User) -> None:
    """Sent after the response, so a slow Gmail never delays login."""
    if user.role is not None and user.role.role_name in NOTIFY_ON_LOGIN and user.email:
        when = datetime.now(PH_TIME).strftime("%B %d, %Y at %I:%M %p (PH time)")
        background_tasks.add_task(mail_service.send_login_notice,
                                  user.email, user.first_name, when)


@router.post("/token")  # form-data; this is what Swagger's Authorize button uses
def token_for_swagger(background_tasks: BackgroundTasks,
                      form_data: OAuth2PasswordRequestForm = Depends(), db: Session = Depends(get_db)):
    user = authenticate_user(db, form_data.username, form_data.password)
    response = build_login_response(user)
    _queue_login_notice(background_tasks, user)
    return response


@router.post("/auth/login")  # JSON; this is what Flutter calls
def login(payload: LoginRequest, background_tasks: BackgroundTasks, db: Session = Depends(get_db)):
    user = authenticate_user(db, payload.email, payload.password)
    response = build_login_response(user)
    _queue_login_notice(background_tasks, user)
    return response


@router.get("/auth/me")  # Flutter calls this on app start to restore the session
def me(user: User = Depends(get_current_user)):
    return user_payload(user)
