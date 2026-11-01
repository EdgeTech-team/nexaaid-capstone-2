import hashlib
import hmac
import re
import threading
import time
from datetime import datetime, timedelta, timezone
from fastapi import Depends, HTTPException, status
from fastapi.security import OAuth2PasswordBearer
import jwt                                    # PyJWT (F-22, replaces python-jose)
from core.log_privacy import hide_query_strings_in_access_log

# F-22: the access log keeps method, path and status, not the query string.
hide_query_strings_in_access_log()

from passlib.context import CryptContext
from sqlalchemy import func
from sqlalchemy.orm import Session

from core.database import get_db
from core.config import settings
from models.user_rbac_model import User
from models.organization_model import Organization

pwd_context = CryptContext(schemes=["bcrypt"], deprecated="auto")
oauth2_scheme = OAuth2PasswordBearer(tokenUrl="token")

# F-02: failed sign-ins per email/username, kept in server memory (no table,
# no migration). After LOGIN_MAX_FAILURES wrong passwords within
# LOGIN_WINDOW_SECONDS, that login must wait. Counted for unknown logins too,
# so the answer never shows whether an account exists. Starts empty again
# when the server restarts.
LOGIN_MAX_FAILURES = 5
LOGIN_WINDOW_SECONDS = 15 * 60
_now = time.monotonic
_failed_logins: dict = {}
_failed_lock = threading.Lock()


def _recent_failures(key: str) -> list:
    cutoff = _now() - LOGIN_WINDOW_SECONDS
    recent = [t for t in _failed_logins.get(key, ()) if t > cutoff]
    if recent:
        _failed_logins[key] = recent
    else:
        _failed_logins.pop(key, None)
    return recent


def _check_login_cooldown(key: str, what: str = "sign-in") -> None:
    with _failed_lock:
        recent = _recent_failures(key)
    if len(recent) >= LOGIN_MAX_FAILURES:
        wait = int(recent[0] + LOGIN_WINDOW_SECONDS - _now()) + 1
        raise HTTPException(
            status_code=status.HTTP_429_TOO_MANY_REQUESTS,
            detail=f"Too many failed {what} attempts. Try again in {(wait + 59) // 60} minute(s).",
            headers={"Retry-After": str(wait)},
        )


def _record_login_failure(key: str) -> None:
    with _failed_lock:
        if len(_failed_logins) > 10_000:          # keep memory small
            for k in list(_failed_logins):
                _recent_failures(k)
        _failed_logins[key] = _recent_failures(key) + [_now()]


def clear_failed_logins(key: str | None = None) -> None:
    """Forget failed sign-ins: one login after it succeeds, or all (tests)."""
    with _failed_lock:
        if key is None:
            _failed_logins.clear()
        else:
            _failed_logins.pop(key, None)


# F-17: the same counter limits a guest's phone check when cancelling a
# donation: 5 wrong tries per donation in 15 minutes, then wait. Keyed by the
# donation's reference (upper case, so it never meets a login key, which is
# lower case). Staff and logged-in donors never reach it.
def check_guest_cancel_attempts(reference: str) -> None:
    _check_login_cooldown(f"guest-cancel:{reference}", "cancel")


def record_guest_cancel_failure(reference: str) -> None:
    _record_login_failure(f"guest-cancel:{reference}")



def hash_password(password: str) -> str:
    return pwd_context.hash(password)


def verify_password(plain: str, hashed: str) -> bool:
    return pwd_context.verify(plain, hashed)


def password_stamp(user: User) -> str:
    """F-10: a short fingerprint of the account's current password hash,
    written into every token. Keyed with SECRET_KEY, so a token (anyone
    holding it can read its claims) shows nothing about the hash."""
    return hmac.new(settings.SECRET_KEY.encode(), (user.password_hash or "").encode(),
                    hashlib.sha256).hexdigest()[:16]


def has_temporary_password(user) -> bool:
    return getattr(user, "must_change_password", False) in (True, 1, "1", "true")



def create_access_token(data: dict) -> str:
    to_encode = data.copy()
    expire = datetime.now(timezone.utc) + timedelta(minutes=settings.ACCESS_TOKEN_EXPIRE_MINUTES)
    to_encode.update({"exp": expire})
    return jwt.encode(to_encode, settings.SECRET_KEY, algorithm=settings.ALGORITHM)


def user_payload(user: User) -> dict:
    return {
        "must_change_password": has_temporary_password(user),
        "user_id": user.user_id,
        "first_name": user.first_name,
        "last_name": user.last_name,
        "email": user.email,
        "role_name": user.role.role_name,
        "organization_id": user.organization_id,
        "assigned_barangay_id": user.assigned_barangay_id,
        "must_change_password": user.must_change_password in (True, 1, "1", "true"),
    }


def authenticate_user(db: Session, email: str, password: str) -> User:
    """Shared login check used by /token (Swagger) and /auth/login (Flutter).

    The first argument is still called `email` so existing callers keep
    working, but it may also be an organization's username. A value with an
    "@" is looked up as an email; anything else as a username (usernames can
    never contain "@", and are saved in lowercase)."""
    login = (email or "").strip()
    key = login.lower()
    _check_login_cooldown(key)                          # F-02
    if "@" in login:
        user = db.query(User).filter(func.lower(User.email) == login.lower()).first()
    elif login:
        user = db.query(User).filter(User.username == login.lower()).first()
    else:
        user = None
    # Same message for unknown email/username and wrong password, so accounts can't be probed
    if not user or not verify_password(password, user.password_hash):
        _record_login_failure(key)                      # F-02
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Incorrect email or password",
            headers={"WWW-Authenticate": "Bearer"},
        )
    clear_failed_logins(key)
    if not user.is_active:
        # Only shown after the password is right, so it can't be used to probe accounts.
        reason = (user.deactivation_reason or "").strip()
        detail = "Account is deactivated."
        detail += f" Reason: {reason}" if reason else " No reason was recorded."
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail=detail)
    return user



def build_login_response(user: User) -> dict:
    token = create_access_token({"sub": user.email, "uid": user.user_id, "role": user.role.role_name,
                                 "pwd": password_stamp(user)})        # F-10
    return {
        "access_token": token,
        "token_type": "bearer",
        "expires_in": settings.ACCESS_TOKEN_EXPIRE_MINUTES * 60,
        "user": user_payload(user),
    }


def _uid_matches(payload: dict, user: User) -> bool:
    uid = payload.get("uid")
    return uid is None or uid == user.user_id


TEMPORARY_PASSWORD_DETAIL = "Change your temporary password first (Profile > Change password)."


def _user_from_token(token: str, db: Session) -> User | None:
    """The account a token belongs to, or None when the token is invalid or
    expired, its email now belongs to someone else, or it was issued before
    the password last changed (F-10)."""
    try:
            # PyJWT checks the signature, the algorithm and "exp" (F-22)
        payload = jwt.decode(token, settings.SECRET_KEY, algorithms=[settings.ALGORITHM])
    except jwt.PyJWTError:
        return None

    email = payload.get("sub")
    if email is None:
        return None
    user = db.query(User).filter(User.email == email).first()
    # Every token carries uid (build_login_response). If it doesn't match, the
    # email now belongs to someone else (Appendix H 1.2: a deleted account's
    # email can be registered again), so the old token must not log in as
    # the new owner.
    if user is None or not _uid_matches(payload, user):
        return None
    # F-10: a password change, a reset or an account deletion makes a new
    # hash, so every token issued before it stops here. Tokens from before
    # F-10 have no stamp and stop here too (users sign in once more).
    if not hmac.compare_digest(str(payload.get("pwd", "")), password_stamp(user)):
        return None
    return user


def get_current_user_allow_temporary_password(
    token: str = Depends(oauth2_scheme), db: Session = Depends(get_db),
) -> User:
    """Signed in, with or without a temporary password. Only for what the
    app needs to change it: POST /auth/change-password, GET /auth/me and
    GET /health/secure (the app reads the role there right after login)."""
    user = _user_from_token(token, db)
    if user is None:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Could not validate credentials (invalid or expired token)",
            headers={"WWW-Authenticate": "Bearer"},
        )
    if not user.is_active:  # deactivation takes effect immediately, even on old tokens
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Account is deactivated")
    return user


def get_current_user(user: User = Depends(get_current_user_allow_temporary_password)) -> User:
    """Every other signed-in endpoint. F-10: the server, not only the app,
    makes an account change its temporary password before anything else."""
    if has_temporary_password(user):
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail=TEMPORARY_PASSWORD_DETAIL)
    return user


# Same token URL, but auto_error=False so a missing token doesn't raise 401
oauth2_scheme_optional = OAuth2PasswordBearer(tokenUrl="token", auto_error=False)

def get_current_user_optional(
    token: str | None = Depends(oauth2_scheme_optional),
    db: Session = Depends(get_db),
) -> User | None:
    if token is None:
        return None
    user = _user_from_token(token, db)
    if user is None:
        return None
    # Mariquit (#85): deactivated accounts can't use existing tokens here
    # either, same as get_current_user.
    if not user.is_active:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Account is deactivated")
    # F-10: until the temporary password is changed, public pages answer as
    # for a guest (nothing role-specific).
    if has_temporary_password(user):
        return None
    return user

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

def can_view_unvalidated_report(user, report) -> bool:
    """F-05: who may open a report that is not validated yet (Pending,
    Rejected or Cancelled). Validated reports keep their own, wider rules.
      - the person who submitted it;
      - CSWS staff (Main Office, Disaster Unit) and the Administrator;
      - a Barangay Receiving Representative, only in its assigned barangay
        (UC-B1 alt 3a, the rule of barangay_scope). Without an assigned
        barangay: none, and no error, so validated reports still open.
    Everyone else (donors, organizations, CMO, DRRMO, guests): no."""
    if user is None:
        return False
    if report.user_id == user.user_id or has_role(user, "csws_staff", "admin"):
        return True
    if has_role(user, "barangay_official"):
        own = getattr(user, "assigned_barangay_id", None)
        return own is not None and own == report.barangay_id
    return False



def require_role(*allowed_roles):
    def role_checker(user: User = Depends(get_current_user)):
        if not has_role(user, *allowed_roles):
            raise HTTPException(status_code=403, detail="You do not have permission to access this resource")
        return user
    return role_checker