"""Server-generated temporary passwords for new internal accounts (UC-A1 step 4).

The Administrator never types or sees this password. It is hashed before it is
stored and emailed once to the staff member (see create_internal_account).
Look-alike characters (I, O, l, 0, 1) are left out so it is easy to type.
"""
import secrets
import string

_UPPER = "ABCDEFGHJKLMNPQRSTUVWXYZ"
_LOWER = "abcdefghijkmnopqrstuvwxyz"
_DIGITS = "23456789"
_SYMBOLS = "@#$%&*!?"


def generate_temp_password(length: int = 12) -> str:
    """At least one upper, lower, digit and symbol; the rest random."""
    length = max(length, 8)
    chars = [
        secrets.choice(_UPPER),
        secrets.choice(_LOWER),
        secrets.choice(_DIGITS),
        secrets.choice(_SYMBOLS),
    ]
    pool = _UPPER + _LOWER + _DIGITS + _SYMBOLS
    chars += [secrets.choice(pool) for _ in range(length - len(chars))]
    secrets.SystemRandom().shuffle(chars)
    return "".join(chars)