"""Termination of donations that are never handed over.

Not in the manuscript: section 3.2 creates a "pending physical donation
record" but nothing ever closes it, so a donor who never shows up stayed
Pending forever and kept CSWS's pending list (7.1 item 1) and counts wrong.
Team decision (Oct 9, 2026), an addition to the spec:

  Expired    the system closes Pending items whose handover deadline passed.
               Drop Off      14 days after the donation was submitted
               Door to Door  14 days after it was submitted, on one of the
                             donor's pickup days (Oct 10: the donor picks
                             days, Mon / Tue / ..., not one time)
                             Older entries with one preferred pickup time:
                             7 days after that time
  Cancelled  the donor (or CSWS on the donor's behalf) withdraws Pending items.

Nothing is deleted. Closed items keep their row with closed_at, close_reason
and closed_by_user_id (NULL = closed by the system), so donor history (UC-D3)
and the audit trail (Table 38) stay complete. Received goods are never
touched: in a partly received donation only the items still Pending close,
so inventory never changes here.

CSWS can reinstate an Expired or Cancelled donation (for example the donor
arrives late with the QR, UC-CM1 alt 2a). It goes back to Pending with a
fresh deadline.

The deadlines can be changed in backend/app/.env without new code:
    DONATION_DROPOFF_DAYS=14
    DONATION_PICKUP_GRACE_DAYS=7
    DONATION_PICKUP_WINDOW_DAYS=14
    DONATION_REMINDER_DAYS=3

There is no background scheduler: expire_overdue() runs at the start of the
screens that show pending donations (cheap, one indexed query), and
POST /donations/expiry/run lets CSWS or a cron run it on demand.
"""
import os
from datetime import datetime, timedelta, timezone
from typing import Iterable, Optional

from sqlalchemy.orm import Session

from core.notifications import notify_event
from models.physical_donation_model import PhysicalDonation
from schemas.physical_donation_schema import MANILA

OPEN = "Pending"
CLOSED = ("Expired", "Cancelled")


def _env_days(name: str, default: int) -> int:
    try:
        value = int(os.getenv(name, default))
    except ValueError:
        return default
    return value if value > 0 else default


def expiry_rules() -> dict:
    drop_off = _env_days("DONATION_DROPOFF_DAYS", 14)
    pickup = _env_days("DONATION_PICKUP_GRACE_DAYS", 7)
    window = _env_days("DONATION_PICKUP_WINDOW_DAYS", 14)
    reminder = _env_days("DONATION_REMINDER_DAYS", 3)
    return {
        "drop_off_days": drop_off,
        "pickup_grace_days": pickup,
        "pickup_window_days": window,
        "reminder_days": reminder,
        # Plain sentences the app shows as they are.
        "drop_off_label": (
            f"Please bring your donation within {drop_off} days. "
            f"After that it is marked Expired."
        ),
        "pickup_label": (
            f"CSWS collects it on one of your pickup days within {window} days. "
            f"If it cannot be collected by then, it is marked Expired."
        ),
    }


def utc(value: Optional[datetime]) -> Optional[datetime]:
    """Stored times are UTC; SQLite hands them back without a timezone."""
    if value is None:
        return None
    return value.replace(tzinfo=timezone.utc) if value.tzinfo is None else value.astimezone(timezone.utc)


def now_utc() -> datetime:
    return datetime.now(timezone.utc)


def nice_date(value: Optional[datetime]) -> str:
    """'Fri, Oct 23' in Philippine time, for messages people read."""
    v = utc(value)
    return v.astimezone(MANILA).strftime("%a, %b %d").replace(" 0", " ") if v else ""


def deadline_for(handover_method: str, preferred_pickup_at: Optional[datetime],
                 start: Optional[datetime] = None) -> datetime:
    """When a Pending donation expires. start = when it was submitted
    (or reinstated); defaults to now."""
    rules = expiry_rules()
    start = utc(start) or now_utc()
    if handover_method == "Door to Door":
        if preferred_pickup_at is not None:  # entries from before pickup days
            return utc(preferred_pickup_at) + timedelta(days=rules["pickup_grace_days"])
        return start + timedelta(days=rules["pickup_window_days"])
    return start + timedelta(days=rules["drop_off_days"])


def set_deadline(rows: Iterable[PhysicalDonation], start: Optional[datetime] = None) -> None:
    """Give newly created (or reinstated) Pending rows their deadline."""
    for r in rows:
        r.expires_at = deadline_for(r.handover_method, r.preferred_pickup_at, start)
        r.reminder_sent_at = None


def effective_deadline(row: PhysicalDonation) -> Optional[datetime]:
    """expires_at, or for rows saved before expiry existed, the rule."""
    if row.status != OPEN:
        return None
    if row.expires_at is not None:
        return utc(row.expires_at)
    return deadline_for(row.handover_method, row.preferred_pickup_at, row.created_at)


def close_rows(rows: Iterable[PhysicalDonation], status: str, reason: str,
               user_id: Optional[int] = None, when: Optional[datetime] = None) -> list:
    """Mark the Pending rows among `rows` Expired or Cancelled. Returns the
    rows that changed. Received / Confirmed rows are left alone."""
    assert status in CLOSED
    when = when or now_utc()
    changed = []
    for r in rows:
        if r.status != OPEN:
            continue
        r.status = status
        r.closed_at = when
        r.close_reason = reason
        r.closed_by_user_id = user_id
        changed.append(r)
    return changed


def reopen_rows(rows: Iterable[PhysicalDonation], preferred_pickup_at: Optional[datetime] = None,
                when: Optional[datetime] = None) -> list:
    """Reinstate Expired / Cancelled rows: back to Pending, fresh deadline."""
    when = when or now_utc()
    changed = []
    for r in rows:
        if r.status not in CLOSED:
            continue
        r.status = OPEN
        r.closed_at = None
        r.close_reason = None
        r.closed_by_user_id = None
        if preferred_pickup_at is not None and r.handover_method == "Door to Door":
            r.preferred_pickup_at = preferred_pickup_at
        changed.append(r)
    # A Door to Door donation reinstated without a new pickup time gets the
    # Drop Off window from today, never a deadline that has already passed.
    for r in changed:
        deadline = deadline_for(r.handover_method, r.preferred_pickup_at, when)
        if deadline <= when:
            deadline = deadline_for("Drop Off", None, when)
        r.expires_at = deadline
        r.reminder_sent_at = None
    return changed


def _by_batch(rows: Iterable[PhysicalDonation]) -> dict:
    out: dict = {}
    for r in rows:
        out.setdefault(r.batch_reference, []).append(r)
    return out


def expire_overdue(db: Session, now: Optional[datetime] = None) -> dict:
    """Close every Pending item past its deadline and remind donors whose
    deadline is near. Safe to call often: it only touches rows that need it.
    Does not commit (get_db commits with the request)."""
    now = utc(now) or now_utc()
    rules = expiry_rules()

    # Rows saved before this feature (or by older code paths) get a deadline.
    for r in db.query(PhysicalDonation).filter(
        PhysicalDonation.status == OPEN, PhysicalDonation.expires_at.is_(None)
    ).all():
        r.expires_at = deadline_for(r.handover_method, r.preferred_pickup_at, r.created_at)
    db.flush()

    # skip_locked: if two screens load at the same moment, the second one
    # skips rows the first is already closing, so nobody is notified twice.
    # (SQLite, used by the tests, ignores this.)
    overdue = db.query(PhysicalDonation).filter(
        PhysicalDonation.status == OPEN, PhysicalDonation.expires_at <= now
    ).with_for_update(skip_locked=True).all()
    expired_batches = _by_batch(overdue)
    for ref, rows in expired_batches.items():
        how = "brought to the CSWS office" if rows[0].handover_method == "Drop Off" else "collected"
        reason = f"Not {how} by {nice_date(rows[0].expires_at)}."
        close_rows(rows, "Expired", reason, user_id=None, when=now)
        if rows[0].user_id:
            notify_event(db, rows[0].user_id, "donation_expired", "donation",
                         rows[0].donation_id, batch_no=ref)

    soon = now + timedelta(days=rules["reminder_days"])
    due = db.query(PhysicalDonation).filter(
        PhysicalDonation.status == OPEN,
        PhysicalDonation.expires_at > now,
        PhysicalDonation.expires_at <= soon,
        PhysicalDonation.reminder_sent_at.is_(None),
    ).with_for_update(skip_locked=True).all()
    reminded = _by_batch(due)
    for ref, rows in reminded.items():
        for r in rows:
            r.reminder_sent_at = now
        if rows[0].user_id:
            notify_event(db, rows[0].user_id, "donation_expiring_soon", "donation",
                         rows[0].donation_id, batch_no=ref, date=nice_date(rows[0].expires_at))
    db.flush()
    return {
        "expired_entries": len(expired_batches),
        "expired_items": len(overdue),
        "reminded_entries": len(reminded),
    }


def entry_status(statuses: Iterable[str]) -> str:
    """One status for a whole donation entry (all items of one QR).

    Closed items only decide the status when every item is closed;
    otherwise the open items decide it (a donation with 2 items received and
    1 expired reads "Received", and closed_items says 1 item was closed).
    """
    s = set(statuses)
    open_ = s - set(CLOSED)
    if not open_:
        return "Cancelled" if s == {"Cancelled"} else "Expired"
    if len(open_) == 1:
        return next(iter(open_))
    return "Partly Received" if OPEN in open_ else "Received"


def entry_expiry_info(rows: list) -> dict:
    """Deadline and closing details for one entry, for the screens."""
    pending = [r for r in rows if r.status == OPEN]
    closed = [r for r in rows if r.status in CLOSED]
    deadline = min((effective_deadline(r) for r in pending), default=None)
    last = max(closed, key=lambda r: utc(r.closed_at) or datetime.min.replace(tzinfo=timezone.utc)) if closed else None
    days_left = None
    if deadline is not None:
        days_left = max(0, (deadline.astimezone(MANILA).date() - now_utc().astimezone(MANILA).date()).days)
    return {
        "expires_at": deadline.isoformat() if deadline else None,
        "expires_label": nice_date(deadline) if deadline else None,
        "days_left": days_left,
        "closed_items": len(closed),
        "closed_at": utc(last.closed_at).isoformat() if last and last.closed_at else None,
        "close_reason": last.close_reason if last else None,
        "closed_by_system": bool(last) and last.closed_by_user_id is None,
    }
