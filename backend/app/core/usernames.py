# core/usernames.py
"""Rules for the organization login username (users.username).

Usernames are saved in lowercase, so "CTU_Org" and "ctu_org" are the same
account. They can never contain "@", which is how login tells a username
from an email address. Keep this in step with usernameError() in
mobile/lib/ui/register_screen.dart.
"""
import re

USERNAME_MIN = 4
USERNAME_MAX = 30

# Names that could be mistaken for staff or the system.
RESERVED_USERNAMES = frozenset({"admin", "administrator", "nexaaid", "support", "root"})

_USERNAME_RE = re.compile(r"^[a-z][a-z0-9_.]*$")


def clean_username(value: str) -> str:
    """Returns the lowercase username, or raises ValueError with a message
    that is safe to show to the person registering."""
    v = (value or "").strip().lower()
    if not (USERNAME_MIN <= len(v) <= USERNAME_MAX):
        raise ValueError(f"Username must be {USERNAME_MIN} to {USERNAME_MAX} characters")
    if not _USERNAME_RE.match(v):
        raise ValueError(
            "Username must start with a letter and use only letters, numbers, "
            "underscores or periods"
        )
    if ".." in v or v.endswith("."):
        raise ValueError("Username cannot have two periods in a row or end with a period")
    if v in RESERVED_USERNAMES:
        raise ValueError("That username is not available")
    return v