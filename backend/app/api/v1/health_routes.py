from fastapi import APIRouter, Depends
from core.auth import get_current_user
from models.user_rbac_model import User

router = APIRouter()

@router.get("/health")
def health():
    return {"status": "ok"}

@router.get("/health/secure")
def health_secure(user: User = Depends(get_current_user)):
    return {"status": "ok", "user": user.email, "role": user.role.role_name}

from fastapi.security import OAuth2PasswordRequestForm
from sqlalchemy.orm import Session
from fastapi import HTTPException, status
from core.database import get_db
from core.auth import create_access_token, verify_password
from models.organization_model import Organization


# TEMPORARY — for testing auth only. Replace with Hoyohoy's real /auth/login in 3.3.
@router.post("/token")
def login_for_access_token(form_data: OAuth2PasswordRequestForm = Depends(), db: Session = Depends(get_db)):
    user = db.query(User).filter(User.email == form_data.username).first()
    if not user or not verify_password(form_data.password, user.password_hash):
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Incorrect username or password")
    # Manuscript User Management alt flow 3b: tell inactive / pending users why.
    if not user.is_active:
        raise HTTPException(status_code=403, detail="This account is deactivated. Contact the Administrator.")
    if user.organization_id is not None:
        org = db.get(Organization, user.organization_id)
        if org is not None and org.status != "Approved":
            raise HTTPException(
                status_code=403,
                detail=f"Your organization registration is {org.status}. "
                       "It needs Administrator approval before you can log in.",
            )
    token = create_access_token(data={"sub": user.email})
    return {"access_token": token, "token_type": "bearer"}