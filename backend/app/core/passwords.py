import re
import secrets

_UPPER = "ABCDEFGHJKLMNPQRSTUVWXYZ"    # no I, O
_LOWER = "abcdefghijkmnopqrstuvwxyz"   # no l
_DIGITS = "23456789"                   # no 0, 1
_SYMBOLS = "!@#$%^&*?"

_COMMON = {
    "password", "password1", "password123", "12345678", "123456789", "qwerty123",
    "iloveyou", "admin123", "welcome1", "letmein123", "nexaaid123", "p@ssw0rd",
}


def generate_temp_password(length: int = 12) -> str:
    """Cryptographically random, guaranteed to contain upper+lower+digit+symbol."""
    pools = [_UPPER, _LOWER, _DIGITS, _SYMBOLS]
    chars = [secrets.choice(p) for p in pools]
    everything = "".join(pools)
    chars += [secrets.choice(everything) for _ in range(length - len(chars))]
    secrets.SystemRandom().shuffle(chars)
    return "".join(chars)


def validate_password_strength(password: str, email: str | None = None, names: tuple = ()) -> None:
    """Raises ValueError with a user-readable message. Used for password CHANGES."""
    if not (8 <= len(password) <= 64):
        raise ValueError("Password must be 8-64 characters")
    if not re.fullmatch(r"[\x21-\x7e]+", password):
        raise ValueError("Password may only use standard keyboard characters (no spaces or emojis)")
    if not re.search(r"[A-Z]", password):
        raise ValueError("Password needs at least one uppercase letter")
    if not re.search(r"[a-z]", password):
        raise ValueError("Password needs at least one lowercase letter")
    if not re.search(r"\d", password):
        raise ValueError("Password needs at least one number")
    if not re.search(r"[^A-Za-z0-9]", password):
        raise ValueError("Password needs at least one special character")
    if password.lower() in _COMMON:
        raise ValueError("That password is too common. Choose something harder to guess")
    low = password.lower()
    if email and email.split("@")[0].lower() in low and len(email.split("@")[0]) >= 4:
        raise ValueError("Password must not contain your email name")
    for n in names:
        if n and len(n) >= 4 and n.lower() in low:
            raise ValueError("Password must not contain your name")