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

# Login (/token, /auth/login, /auth/me) lives in api/v1/session_router.py.
