import re
from datetime import datetime, timedelta
from fastapi import Depends, HTTPException, status
from fastapi.security import OAuth2PasswordBearer
from jose import JWTError, jwt
from passlib.context import CryptContext
from sqlalchemy.orm import Session

from core.database import get_db
from core.config import settings
from models.user_rbac_model import User

pwd_context = CryptContext(schemes=["bcrypt"], deprecated="auto")
oauth2_scheme = OAuth2PasswordBearer(tokenUrl="token")
oauth2_scheme_optional = OAuth2PasswordBearer(tokenUrl="token", auto_error=False)

def hash_password(password: str) -> str:
    return pwd_context.hash(password)

def verify_password(plain: str, hashed: str) -> bool:
    return pwd_context.verify(plain, hashed)

def create_access_token(data: dict) -> str:
    to_encode = data.copy()
    expire = datetime.utcnow() + timedelta(minutes=settings.ACCESS_TOKEN_EXPIRE_MINUTES)
    to_encode.update({"exp": expire})
    return jwt.encode(to_encode, settings.SECRET_KEY, algorithm=settings.ALGORITHM)

def get_current_user(token: str = Depends(oauth2_scheme), db: Session = Depends(get_db)) -> User:
    credentials_exception = HTTPException(
        status_code=status.HTTP_401_UNAUTHORIZED, detail="Could not validate credentials"
    )
    try:
        payload = jwt.decode(token, settings.SECRET_KEY, algorithms=[settings.ALGORITHM])
        email: str = payload.get("sub")
        if email is None:
            raise credentials_exception
    except JWTError:
        raise credentials_exception

    user = db.query(User).filter(User.email == email).first()
    if user is None or not user.is_active:
        raise credentials_exception
    return user

def get_current_user_optional(
    token: str = Depends(oauth2_scheme_optional),
    db: Session = Depends(get_db),
) -> User | None:
    if token is None:
        return None
    try:
        payload = jwt.decode(token, settings.SECRET_KEY, algorithms=[settings.ALGORITHM])
        email: str = payload.get("sub")
        if email is None:
            return None
    except JWTError:
        return None
    return db.query(User).filter(User.email == email).first()

def _norm_role(name) -> str:
    """'CSWS Main Office' / 'csws_main_office' -> 'csws_main_office'"""
    return re.sub(r"[^a-z0-9]+", "_", (name or "").lower()).strip("_")

# Routers use different spellings ("Administrator" vs "admin", etc.).
# This maps every spelling used in the codebase onto the real roles
# in the `roles` table (checked against Neon on Sep 30).
_ROLE_GROUPS = {
    "admin": {"admin", "administrator"},
    "administrator": {"admin", "administrator"},
    "csws_staff": {"csws_main_office", "csws_disaster_unit"},
    "barangay_official": {"barangay_receiving_representative", "barangay_receiving_rep"},
    "barangay_receiving_rep": {"barangay_receiving_representative", "barangay_receiving_rep"},
    "barangay_receiving_representative": {"barangay_receiving_representative", "barangay_receiving_rep"},
}

def expand_roles(*roles) -> set:
    allowed = set()
    for r in roles:
        n = _norm_role(r)
        allowed.add(n)
        allowed |= _ROLE_GROUPS.get(n, set())
    return allowed

def has_role(user: User, *roles) -> bool:
    return user.role is not None and _norm_role(user.role.role_name) in expand_roles(*roles)

def barangay_scope(user: User):
    """Barangay Receiving Representatives only see and act on their own
    assigned barangay (manuscript UC-B1, alt flow 3a). Returns that
    barangay_id for them, or None for every other role (no restriction)."""
    if not has_role(user, "barangay_receiving_rep"):
        return None
    barangay_id = getattr(user, "assigned_barangay_id", None)
    if barangay_id is None:
        raise HTTPException(
            status_code=403,
            detail="Your account has no assigned barangay. Ask the Administrator to set one.",
        )
    return barangay_id

def require_role(*allowed_roles):
    def role_checker(user: User = Depends(get_current_user)):
        if not has_role(user, *allowed_roles):
            raise HTTPException(status_code=403, detail="You do not have permission to access this resource")
        return user
    return role_checker