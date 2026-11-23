"""NF-004 / NF-005 (D1, D2): what a guest (no account) may donate.

Agreement A9: guests donate without an account, with limits per phone
number, per connection and per day. Door to Door for guests is a setting,
GUEST_DOOR_TO_DOOR in .env (no code change to switch):
  blocked  (default)  guests choose Drop Off only; Door to Door needs an
                      account (verified email + confirmation call)      422
  limited             guests may ask for Door to Door, at most
                      GUEST_MAX_OPEN_PICKUPS (1) waiting per number     429
Logged-in donors never reach these checks.

  Per phone number       at most GUEST_MAX_OPEN_ENTRIES (2) Pending
                         guest entries per normalized number            429
  Per connection         at most GUEST_MAX_PER_IP_HOUR (5) guest
                         submissions an hour (core/auth.py, in memory)  429
  Duplicates             same number + same report + same item within
                         24 hours                                       409
  Quantity cap           each item line at most GUEST_MAX_LINE_QTY
                         base units (kg, L, pcs ...)                    422
  Bot trap               the hidden "website" field is filled in: answer
                         201, save nothing
  Fewer notifications    guest entries notify only CSWS Main Office, at
                         most one notice per 10 minutes per person
                         ("3 new guest donations")

Every number can be changed in backend/app/.env (see .env.example).
"""
import os
from datetime import timedelta
from typing import Iterable, Optional

from fastapi import HTTPException
from sqlalchemy import func
from sqlalchemy.orm import Session

from core.notifications.notifications import notify, user_ids_with_role
from core.m4_donation_management.guest_donor_model import GuestDonor
from core.notifications.notification_model import Notification
from core.m4_donation_management.physical_donation_model import PhysicalDonation
from core.m4_donation_management.donation_expiry import now_utc

GUEST_DOOR_TO_DOOR_BLOCKED = (
    "For the safety of our pickup team, Door to Door is for registered donors. "
    "Sign in or register, or choose Drop Off."
)
GUEST_ONE_PICKUP = (
    "For NexaAid security and the safety of our pickup team, a guest can have only "
    "one Door to Door pickup waiting at a time. Please wait until CSWS collects it, "
    "choose Drop Off, or register an account to request more pickups."
)
GUEST_LARGE = "For large donations please sign in."
GUEST_NOTICE = "guest_donations_submitted"
NOTICE_MINUTES = 10
DUPLICATE_HOURS = 24


def _env_int(name: str, default: int) -> int:
    try:
        value = int(os.getenv(name, default))
    except ValueError:
        return default
    return value if value > 0 else default


def max_open_entries() -> int:
    return _env_int("GUEST_MAX_OPEN_ENTRIES", 2)


def guest_door_to_door() -> str:
    """'blocked' (default) or 'limited' (GUEST_DOOR_TO_DOOR in .env)."""
    mode = os.getenv("GUEST_DOOR_TO_DOOR", "blocked").strip().lower()
    return mode if mode in ("blocked", "limited") else "blocked"


def check_handover(handover_method: str) -> None:
    """Guests and Door to Door, by the GUEST_DOOR_TO_DOOR setting."""
    if handover_method == "Door to Door" and guest_door_to_door() == "blocked":
        raise HTTPException(status_code=422, detail=GUEST_DOOR_TO_DOOR_BLOCKED)


def max_open_pickups() -> int:
    return _env_int("GUEST_MAX_OPEN_PICKUPS", 1)


def max_line_qty() -> int:
    return _env_int("GUEST_MAX_LINE_QTY", 100)


def check_open_pickups(db: Session, phone: str) -> None:
    """A guest number may have one Door to Door pickup waiting. Every pickup
    sends staff and a vehicle to an address nobody has checked, so a guest
    gets one at a time; a registered donor (verified email) gets more."""
    waiting = (_guest_rows(db, phone)
               .filter(PhysicalDonation.status == "Pending",
                       PhysicalDonation.handover_method == "Door to Door")
               .with_entities(func.count(func.distinct(PhysicalDonation.batch_reference)))
               .scalar() or 0)
    if waiting >= max_open_pickups():
        raise HTTPException(status_code=429, detail=GUEST_ONE_PICKUP)


def is_bot(website: Optional[str]) -> bool:
    """The hidden form field people never see; bots fill in every field."""
    return bool((website or "").strip())


def check_line_quantities(quantities: Iterable[int]) -> None:
    cap = max_line_qty()
    if any((q or 0) > cap for q in quantities):
        raise HTTPException(status_code=422, detail=GUEST_LARGE)


def _guest_rows(db: Session, phone: str):
    return (db.query(PhysicalDonation)
            .join(GuestDonor, GuestDonor.guest_donor_id == PhysicalDonation.guest_donor_id)
            .filter(GuestDonor.contact_number == phone))


def check_open_entries(db: Session, phone: str) -> None:
    """Counted in the database (guest_donors joined to physical_donations)."""
    open_entries = (_guest_rows(db, phone)
                    .filter(PhysicalDonation.status == "Pending")
                    .with_entities(func.count(func.distinct(PhysicalDonation.batch_reference)))
                    .scalar() or 0)
    cap = max_open_entries()
    if open_entries >= cap:
        raise HTTPException(
            status_code=429,
            detail=(f"You already have {cap} donation{'s' if cap != 1 else ''} waiting. "
                    "Bring them to CSWS first, or sign in."),
        )


def check_duplicates(db: Session, phone: str, report_id: int, item_ids: Iterable[int]) -> None:
    since = now_utc() - timedelta(hours=DUPLICATE_HOURS)
    ids = set(item_ids)
    hit =(_guest_rows(db, phone)
           .filter(PhysicalDonation.report_id == report_id,
                   PhysicalDonation.item_id.in_(ids),
                   PhysicalDonation.created_at >= since)
           .first())
    if hit is not None:
        raise HTTPException(
            status_code=409,
            detail=("You already pledged this item to this report in the last 24 hours. "
                    "Bring that donation to CSWS first, or sign in."),
        )


def _notice_count(title: str) -> int:
    """'New guest donation' -> 1, '3 new guest donations' -> 3."""
    head = (title or "").split(" ", 1)[0]
    return int(head) if head.isdigit() else 1


def notify_csws_grouped(db: Session, entity_id: int, batch_no: str) -> None:
    """Guest entries notify only CSWS Main Office, and each person gets at
    most one new notice per NOTICE_MINUTES. Within that time the latest
    unread notice is updated instead ("3 new guest donations"), without a
    new push."""
    now = now_utc()
    since = now - timedelta(minutes=NOTICE_MINUTES)
    for uid in user_ids_with_role(db, ["CSWS Main Office"]):
        recent = (db.query(Notification)
                  .filter(Notification.user_id == uid, Notification.type == GUEST_NOTICE,
                          Notification.is_read.is_(False), Notification.sent_at >= since)
                  .order_by(Notification.notification_id.desc())
                  .first())
        if recent is not None:
            # One more guest entry on the same notice: "3 new guest donations".
            count = _notice_count(recent.title) + 1
            recent.title = f"{count} new guest donations"
            recent.message = (f"{count} guest donations are awaiting receipt. "
                              f"Latest: #{batch_no}.")
            continue
        notify(db, uid, GUEST_NOTICE, "New guest donation",
               f"Guest donation #{batch_no} is awaiting receipt.", "donation", entity_id)
