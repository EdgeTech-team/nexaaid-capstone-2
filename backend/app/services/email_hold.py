"""NF-006 (D4): Door to Door pickups wait for a verified email (agreement A4).

Registration still signs in at once. A Door to Door donation from an
account whose email is not verified yet is saved, but it is "on hold":
  * it stays off GET /donations/pickups, the pickup planner and the CSWS
    map, and cannot be put in a pickup run;
  * it expires after EMAIL_VERIFY_HOLD_HOURS (48) hours, close_reason
    "Email not verified".
When the donor confirms the code (POST /auth/verify-email/confirm), every
Door to Door donation of theirs still waiting appears on the map and its
handover deadline counts from that moment. Verification is once per
account. Drop Off never needs it.
"""
import os
from datetime import timedelta
from typing import Iterable, Optional

from sqlalchemy import or_, select
from sqlalchemy.orm import Session

from models.physical_donation_model import PhysicalDonation
from models.user_rbac_model import User
from services.donation_expiry import now_utc, set_deadline
from services.pledge_trust import email_verified

DOOR = "Door to Door"
HOLD_REASON = "Email not verified"


def hold_hours() -> int:
    try:
        value = int(os.getenv("EMAIL_VERIFY_HOLD_HOURS", 48))
    except ValueError:
        return 48
    return value if value > 0 else 48


def needs_hold(user, handover_method: str) -> bool:
    """A logged-in donor without a verified email asking for a pickup."""
    return handover_method == DOOR and user is not None and not email_verified(user)


def apply_hold(rows: Iterable[PhysicalDonation], user) -> bool:
    """Give held Door to Door rows the 48-hour deadline. True if held."""
    rows = list(rows)
    if not rows or not needs_hold(user, rows[0].handover_method):
        return False
    deadline = now_utc() + timedelta(hours=hold_hours())
    for r in rows:
        r.expires_at = deadline
        r.reminder_sent_at = None
    return True


def not_held():
    """SQL filter: rows that are not waiting for their donor's email."""
    unverified = select(User.user_id).where(User.email_verified_at.is_(None))
    return or_(
        PhysicalDonation.handover_method != DOOR,
        PhysicalDonation.user_id.is_(None),
        PhysicalDonation.user_id.not_in(unverified),
    )


def held_refs(db: Session, refs: Iterable[str]) -> set:
    """Which of these entries are Door to Door waiting for an email."""
    refs = set(refs)
    if not refs:
        return set()
    rows = (db.query(PhysicalDonation.batch_reference)
            .join(User, User.user_id == PhysicalDonation.user_id)
            .filter(PhysicalDonation.batch_reference.in_(refs),
                    PhysicalDonation.handover_method == DOOR,
                    User.email_verified_at.is_(None))
            .distinct().all())
    return {r[0] for r in rows}


def is_held(row: PhysicalDonation, user) -> bool:
    return row.handover_method == DOOR and row.user_id is not None and not email_verified(user)


def release_holds(db: Session, user: User) -> list:
    """After the email is verified: the donor's Door to Door donations still
    waiting get a fresh handover deadline from now. Returns their refs."""
    rows = (db.query(PhysicalDonation)
            .filter(PhysicalDonation.user_id == user.user_id,
                    PhysicalDonation.handover_method == DOOR,
                    PhysicalDonation.status == "Pending")
            .all())
    by_ref: dict = {}
    for r in rows:
        by_ref.setdefault(r.batch_reference, []).append(r)
    now = now_utc()
    for lines in by_ref.values():
        set_deadline(lines, start=now)
    return sorted(by_ref)


def expiry_reason(row: PhysicalDonation, user: Optional[User]) -> Optional[str]:
    """close_reason when a held row expires, else None (the usual reason)."""
    return HOLD_REASON if is_held(row, user) else None
