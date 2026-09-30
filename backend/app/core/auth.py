from datetime import datetime, timedelta, timezone
from fastapi import Depends, HTTPException, status
from fastapi.security import OAuth2PasswordBearer
from jose import JWTError, jwt
from passlib.context import CryptContext
from sqlalchemy import func
from sqlalchemy.orm import Session

from core.database import get_db
from core.config import settings
from models.user_rbac_model import User
from models.organization_model import Organization

pwd_context = CryptContext(schemes=["bcrypt"], deprecated="auto")
oauth2_scheme = OAuth2PasswordBearer(tokenUrl="token")


def hash_password(password: str) -> str:
    return pwd_context.hash(password)


def verify_password(plain: str, hashed: str) -> bool:
    return pwd_context.verify(plain, hashed)


def create_access_token(data: dict) -> str:
    to_encode = data.copy()
    expire = datetime.now(timezone.utc) + timedelta(minutes=settings.ACCESS_TOKEN_EXPIRE_MINUTES)
    to_encode.update({"exp": expire})
    return jwt.encode(to_encode, settings.SECRET_KEY, algorithm=settings.ALGORITHM)


def user_payload(user: User) -> dict:
    return {
        "user_id": user.user_id,
        "first_name": user.first_name,
        "last_name": user.last_name,
        "email": user.email,
        "role_name": user.role.role_name,
        "organization_id": user.organization_id,
        "assigned_barangay_id": user.assigned_barangay_id,
    }


def authenticate_user(db: Session, email: str, password: str) -> User:
    """Shared login check used by /token (Swagger) and /auth/login (Flutter)."""
    user = db.query(User).filter(func.lower(User.email) == email.strip().lower()).first()
    # Same message for unknown email and wrong password, so emails can't be probed
    if not user or not verify_password(password, user.password_hash):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Incorrect email or password",
            headers={"WWW-Authenticate": "Bearer"},
        )
    if not user.is_active:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Account is deactivated")
    if user.organization_id is not None:
        org = db.get(Organization, user.organization_id)
        if org and org.status != "Approved":
            raise HTTPException(
                status_code=status.HTTP_403_FORBIDDEN,
                detail=f"Organization registration is {org.status}. Wait for administrator approval.",
            )
    return user


def build_login_response(user: User) -> dict:
    token = create_access_token({"sub": user.email, "uid": user.user_id, "role": user.role.role_name})
    return {
        "access_token": token,
        "token_type": "bearer",
        "expires_in": settings.ACCESS_TOKEN_EXPIRE_MINUTES * 60,
        "user": user_payload(user),
    }


def get_current_user(token: str = Depends(oauth2_scheme), db: Session = Depends(get_db)) -> User:
    credentials_exception = HTTPException(
        status_code=status.HTTP_401_UNAUTHORIZED,
        detail="Could not validate credentials (invalid or expired token)",
        headers={"WWW-Authenticate": "Bearer"},
    )
    try:
        # python-jose rejects expired tokens automatically (raises JWTError)
        payload = jwt.decode(token, settings.SECRET_KEY, algorithms=[settings.ALGORITHM])
        email: str = payload.get("sub")
        if email is None:
            raise credentials_exception
    except JWTError:
        raise credentials_exception

    user = db.query(User).filter(User.email == email).first()
    if user is None:
        raise credentials_exception
    if not user.is_active:  # deactivation takes effect immediately, even on old tokens
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Account is deactivated")
    return user


# Same token URL, but auto_error=False so a missing token doesn't raise 401
oauth2_scheme_optional = OAuth2PasswordBearer(tokenUrl="token", auto_error=False)

def get_current_user_optional(
    token: str | None = Depends(oauth2_scheme_optional),
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


def require_role(*allowed_roles):
    def role_checker(user: User = Depends(get_current_user)):
        if user.role.role_name not in allowed_roles:
            raise HTTPException(status_code=403, detail="You do not have permission to access this resource")
        return user
    return role_checker