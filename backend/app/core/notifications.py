"""notify(): add an in-app notification, the same way log_action adds an audit row.
The caller's get_db commits it together with the rest of the request.

Two ways to call it:

1) Explicit text (what reports.py does today):
       notify(db, report.user_id, "report_validated", "Report validated", "Your report ...",
              entity_type="report", entity_id=report.report_id)

2) From the catalog below (one line, consistent wording for the whole team):
       notify_event(db, donor_id, "donation_received", "donation_batch", batch.id, batch_no=batch.id)
       notify_event_many(db, [csws_id, brgy_rep_id], "donation_confirmed", "donation_batch", batch.id, batch_no=batch.id)
"""
from typing import Iterable, Optional

from sqlalchemy.orm import Session

from models.notification import Notification
# event -> (title, message template). Missing {placeholders} render as "".
EVENTS: dict[str, tuple[str, str]] = {
    # Organizations
    "org_registered": ("New organization registered", "{name} registered and was approved automatically."),
    "donor_registered": ("New donor registered", "{name} registered as an individual donor."),
    "org_approved": ("Organization approved", "Your organization account is now active."),
    "org_rejected": ("Organization registration rejected", "{reason}"),
    # Reports
    "report_submitted": ("New report submitted", "{title} needs validation."),
    "report_validated": ("Report validated", "{title} has been validated."),
    "report_rejected": ("Report rejected", "{title} was rejected. {reason}"),
    "report_open_for_donations": ("New report needs help", "{title} is now accepting donations."),
    # Donations
    "donation_submitted": ("New donation submitted", "Donation batch #{batch_no} is awaiting receipt."),
    "donation_submitted_confirm": ("Donation submitted", "Thank you! Your donation #{batch_no} was recorded."),
    "donation_received": ("Donation received", "Donation #{batch_no} was received at the CSWS office."),
    "donation_confirmed": ("Donation confirmed", "Donation #{batch_no} was confirmed by the CMO."),
    "donation_held": ("Donation on hold", "Donation #{batch_no} is on hold. {reason}"),
    # Logistics
    "logistics_requested": ("Logistics requested", "CSWS requested transport for {title}."),
    "logistics_accepted": ("Logistics request accepted", "Request for {title} was accepted."),
    "logistics_scheduled": ("Logistics scheduled", "Pickup for {title}: {schedule}."),
    "logistics_declined": ("Logistics request declined", "{reason}"),
    # Delivery
    "delivery_status_changed": ("Delivery update", "{title} is now: {status}."),
    "delivery_receipt_confirmed": ("Receipt confirmed", "The barangay confirmed receipt for {title}."),
    # Accounts (callers also email these with core.email.send_email)
    "account_created": ("Account created", "Your NexaAid account is ready."),
    "account_password_changed": ("Password changed", "Your password was changed."),
}


class _Blank(dict):
    def __missing__(self, key):
        return ""


def render_event(event: str, **ctx) -> tuple[str, str]:
    title, body = EVENTS.get(event, (event, ""))
    return title.format_map(_Blank(ctx)), body.format_map(_Blank(ctx)).strip()


def notify(
    db: Session,
    user_id: int,
    event: str,
    title: str,
    body: Optional[str] = None,
    entity_type: Optional[str] = None,
    entity_id: Optional[int] = None,
) -> Notification:
    n = Notification(
        user_id=user_id,
        type=event,
        title=title,
        message=body or title,
        entity_type=entity_type,
        entity_id=entity_id,
    )
    db.add(n)
    db.flush()
    return n


def notify_many(
    db: Session,
    user_ids: Iterable[int],
    event: str,
    title: str,
    body: Optional[str] = None,
    entity_type: Optional[str] = None,
    entity_id: Optional[int] = None,
) -> int:
    count = 0
    for uid in set(user_ids):
        notify(db, uid, event, title, body, entity_type, entity_id)
        count += 1
    return count


def notify_event(
    db: Session,
    user_id: int,
    event: str,
    entity_type: Optional[str] = None,
    entity_id: Optional[int] = None,
    **ctx,
) -> Notification:
    title, body = render_event(event, **ctx)
    return notify(db, user_id, event, title, body, entity_type, entity_id)


def notify_event_many(
    db: Session,
    user_ids: Iterable[int],
    event: str,
    entity_type: Optional[str] = None,
    entity_id: Optional[int] = None,
    **ctx,
) -> int:
    title, body = render_event(event, **ctx)
    return notify_many(db, user_ids, event, title, body, entity_type, entity_id)

def user_ids_with_role(
    db: Session,
    role_names: Iterable[str],
    exclude_user_id: Optional[int] = None,
    barangay_id: Optional[int] = None,
) -> list[int]:
    """Ids of active users whose role_name is in role_names."""
    from models.role_model import Role  # local import avoids circular imports
    from models.user_rbac_model import User

    q = (
        db.query(User.user_id)
        .join(Role, Role.role_id == User.role_id)
        .filter(Role.role_name.in_(list(role_names)), User.is_active.is_(True))
    )
    if barangay_id is not None:
        q = q.filter(User.assigned_barangay_id == barangay_id)
    return [uid for (uid,) in q.all() if uid != exclude_user_id]
