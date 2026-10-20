import re
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
    expire = datetime.now(timezone.utc) + timedelta(
        minutes=settings.ACCESS_TOKEN_EXPIRE_MINUTES
    )
    to_encode.update({"exp": expire})
    return jwt.encode(
        to_encode,
        settings.SECRET_KEY,
        algorithm=settings.ALGORITHM,
    )


def user_payload(user: User) -> dict:
    return {
        "user_id": user.user_id,
        "first_name": user.first_name,
        "last_name": user.last_name,
        "email": user.email,
        "role_name": user.role.role_name,
        "organization_id": user.organization_id,
        "assigned_barangay_id": user.assigned_barangay_id,
        "must_change_password": user.must_change_password in (
            True, 1, "1", "true"
        ),
    }


def authenticate_user(db: Session, email: str, password: str) -> User:
    """Shared login check used by /token (Swagger) and /auth/login (Flutter).

    The first argument is still called `email` so existing callers keep
    working, but it may also be an organization's username. A value with an
    "@" is looked up as an email; anything else as a username (usernames can
    never contain "@", and are saved in lowercase).
    """
    login = (email or "").strip()

    if "@" in login:
        user = (
            db.query(User)
            .filter(func.lower(User.email) == login.lower())
            .first()
        )
    elif login:
        user = (
            db.query(User)
            .filter(User.username == login.lower())
            .first()
        )
    else:
        user = None

    # Use the same message for unknown email/username and wrong password.
    if not user or not verify_password(password, user.password_hash):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Incorrect email or password",
            headers={"WWW-Authenticate": "Bearer"},
        )

    if not user.is_active:
        # Only shown after the password is correct.
        reason = (user.deactivation_reason or "").strip()
        detail = "Account is deactivated."
        detail += (
            f" Reason: {reason}"
            if reason
            else " No reason was recorded."
        )

        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail=detail,
        )

    return user


def build_login_response(user: User) -> dict:
    token = create_access_token(
        {
            "sub": user.email,
            "uid": user.user_id,
            "role": user.role.role_name,
        }
    )

    return {
        "access_token": token,
        "token_type": "bearer",
        "expires_in": settings.ACCESS_TOKEN_EXPIRE_MINUTES * 60,
        "user": user_payload(user),
    }


def get_current_user(
    token: str = Depends(oauth2_scheme),
    db: Session = Depends(get_db),
) -> User:
    credentials_exception = HTTPException(
        status_code=status.HTTP_401_UNAUTHORIZED,
        detail="Could not validate credentials (invalid or expired token)",
        headers={"WWW-Authenticate": "Bearer"},
    )

    try:
        # Expired tokens are rejected by python-jose.
        payload = jwt.decode(
            token,
            settings.SECRET_KEY,
            algorithms=[settings.ALGORITHM],
        )
        email: str = payload.get("sub")

        if email is None:
            raise credentials_exception

    except JWTError:
        raise credentials_exception

    user = db.query(User).filter(User.email == email).first()

    if user is None:
        raise credentials_exception

    # Deactivation takes effect immediately, even on existing tokens.
    if not user.is_active:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Account is deactivated",
        )

    return user


# Same token URL, but auto_error=False so a missing token doesn't raise 401.
oauth2_scheme_optional = OAuth2PasswordBearer(
    tokenUrl="token",
    auto_error=False,
)


def get_current_user_optional(
    token: str | None = Depends(oauth2_scheme_optional),
    db: Session = Depends(get_db),
) -> User | None:
    if token is None:
        return None

    try:
        payload = jwt.decode(
            token,
            settings.SECRET_KEY,
            algorithms=[settings.ALGORITHM],
        )
        email: str = payload.get("sub")

        if email is None:
            return None

    except JWTError:
        return None

    # Find the user associated with the token.
    user = db.query(User).filter(User.email == email).first()

    if user is None:
        return None

    # Do not allow deactivated accounts to use existing tokens.
    if not user.is_active:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Account is deactivated",
        )

    return user


def _norm_role(name) -> str:
    """'CSWS Main Office' / 'csws_main_office' -> 'csws_main_office'."""
    return re.sub(
        r"[^a-z0-9]+",
        "_",
        (name or "").lower(),
    ).strip("_")


# Routers use different spellings ("Administrator" vs "admin", etc.).
# This maps every spelling used in the codebase onto the real roles
# in the `roles` table.
_ROLE_GROUPS = {
    "admin": {"admin", "administrator"},
    "administrator": {"admin", "administrator"},
    "csws_staff": {"csws_main_office", "csws_disaster_unit"},
    "barangay_official": {
        "barangay_receiving_representative",
        "barangay_receiving_rep",
    },
    "barangay_receiving_rep": {
        "barangay_receiving_representative",
        "barangay_receiving_rep",
    },
    "barangay_receiving_representative": {
        "barangay_receiving_representative",
        "barangay_receiving_rep",
    },
}


def expand_roles(*roles) -> set:
    allowed = set()

    for role in roles:
        normalized_role = _norm_role(role)
        allowed.add(normalized_role)
        allowed |= _ROLE_GROUPS.get(normalized_role, set())

    return allowed


def has_role(user: User, *roles) -> bool:
    return (
        user.role is not None
        and _norm_role(user.role.role_name) in expand_roles(*roles)
    )


def barangay_scope(user: User):
    """Return the assigned barangay ID for receiving representatives.

    Other roles have no barangay restriction.
    """
    if not has_role(user, "barangay_receiving_rep"):
        return None

    barangay_id = getattr(user, "assigned_barangay_id", None)

    if barangay_id is None:
        raise HTTPException(
            status_code=403,
            detail=(
                "Your account has no assigned barangay. "
                "Ask the Administrator to set one."
            ),
        )

    return barangay_id


def require_role(*allowed_roles):
    def role_checker(
        user: User = Depends(get_current_user),
    ):
        if not has_role(user, *allowed_roles):
            raise HTTPException(
                status_code=403,
                detail="You do not have permission to access this resource",
            )

        return user

    return role_checker