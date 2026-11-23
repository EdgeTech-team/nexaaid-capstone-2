"""NF-011 (D3, shared with J6): which pledges can be trusted.

A pledge (one donated item, or one donation entry) is verified when:
  * CSWS has received it (status Received or Confirmed), or
  * it came from a logged-in account whose email is verified (NF-006, D4).
Otherwise it is not verified: a guest pledge until CSWS receives it, or a
pledge from an account that never confirmed its email.

Jenises's "still needed" chips (J6) use pledge_is_verified; the CSWS
pending lists show pledge_flag as a chip.
"""
from typing import Iterable, Optional

RECEIVED = ("Received", "Confirmed")

GUEST_FLAG = "Guest – not yet received"
EMAIL_FLAG = "Email not verified"


def email_verified(user) -> bool:
    return user is not None and getattr(user, "email_verified_at", None) is not None


def pledge_is_verified(donation, user) -> bool:
    """donation: a PhysicalDonation row. user: the account that made it (the
    User row for donation.user_id), or None for a guest."""
    if donation.status in RECEIVED:
        return True
    return donation.user_id is not None and email_verified(user)


def pledge_flag(donation, user) -> Optional[str]:
    """The chip CSWS sees on a pledge that is not verified, else None."""
    if pledge_is_verified(donation, user):
        return None
    return GUEST_FLAG if donation.user_id is None else EMAIL_FLAG


def entry_trust(rows: Iterable, user) -> dict:
    """One entry (all rows of one QR): verified when every item still
    counted is verified. Closed items (Expired / Cancelled) don't count."""
    rows = list(rows)
    live = [r for r in rows if r.status not in ("Expired", "Cancelled")] or rows
    flags = [pledge_flag(r, user) for r in live]
    flag = next((f for f in flags if f), None)
    return {"pledge_verified": flag is None, "pledge_flag": flag}


def users_by_id(db, user_ids) -> dict:
    """{user_id: User} for the accounts behind some rows (one query)."""
    from core.m1_user_management.user_rbac_model import User
    ids = {u for u in user_ids if u}
    if not ids:
        return {}
    return {u.user_id: u for u in db.query(User).filter(User.user_id.in_(ids)).all()}
