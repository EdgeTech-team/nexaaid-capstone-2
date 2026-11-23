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

from core.notifications import push
from core.notifications.realtime import queue_push
from models.notifications.notification import Notification
# event -> (title, message template). Missing {placeholders} render as "".
EVENTS: dict[str, tuple[str, str]] = {
    # Organizations
    # Accounts sign in right away, so the Administrator is reminded to check
    # the ID and documents (and delete the account, with a reason, if fake).
    "org_registered": ("New organization registered",
                       "{name} registered. Tap to review: check the contact person's valid ID "
                       "and the supporting document. Delete the account with a reason "
                       "(e.g. Fake ID, Invalid document) if they are not genuine."),
    "donor_registered": ("New donor registered",
                         "{name} registered as an individual donor. Tap to review: check the "
                         "valid ID (needed for Door to Door pickups). Delete the account with a "
                         "reason (e.g. Fake ID) if it is not genuine."),
    "org_approved": ("Organization approved", "Your organization account is now active."),
    "org_rejected": ("Organization registration rejected", "{reason}"),
    # Reports
    # {title} is the readable label ("Flood in Barangay Looc") and {story}
    # the plain description (services/reports/report_story.py); {report_no} is the
    # report number staff look it up by.
    "report_submitted": ("New report: {title}",
                         "{story} Report #{report_no} needs validation."),
    "report_validated": ("Validated: {title}",
                         "{story} Report #{report_no} is now open for donations."),
    "report_rejected": ("Report rejected", "{title} was rejected. {reason}"),
    "report_open_for_donations": ("{title}: families need your help",
                                  "{story} Tap to see what they need and donate."),
    "report_withdrawn": ("Report withdrawn: {title}",
                         "Report #{report_no} was withdrawn by the Disaster Unit before validation."),
    # Donations
    "donation_submitted": ("New donation submitted", "Donation batch #{batch_no} is awaiting receipt."),
    "donation_submitted_confirm": ("Donation submitted", "Thank you! Your donation #{batch_no} was recorded. Next, CSWS receives it."),
    "donation_received": ("Donation received", "Donation #{batch_no} was received at the CSWS office."),
    "donation_confirmed": ("Donation acknowledged", "Donation #{batch_no} was acknowledged by the CMO."),
    "donation_held": ("Donation on hold", "Donation #{batch_no} is on hold. {reason}"),
    # CSWS Main Office (Oct 17): the CMO's decision on a donation entry.
    "donation_ready_for_delivery": ("Donation acknowledged", "The CMO acknowledged donation #{batch_no} for {report}. It can now go on a delivery."),
    # Oct 23: the donor changed a pledged donation (same QR).
    "donation_items_added": ("Items added to a donation", "The donor added {count} item(s) to donation #{batch_no} (Batch {addition_no}). Collect them together with the rest of the donation."),
    "donation_item_removed": ("Item removed from a donation", "The donor removed {item} from donation #{batch_no}. Reason: {reason}"),
    "donation_held_staff": ("Donation on hold", "The CMO put donation #{batch_no} for {report} on hold. {reason}"),
    # Donors follow their donation's delivery (Oct 17, services/deliveries/delivery_notices.py)
    "donation_in_transit": ("Your donation is on the way", "Donation #{batch_no} left the CSWS office for {barangay} (delivery #{delivery_id})."),
    "donation_delivered": ("Your donation arrived", "Donation #{batch_no} was delivered to {barangay}. The barangay will confirm receipt."),
    "donation_barangay_confirmed": ("The barangay received your donation", "{barangay} confirmed receiving donation #{batch_no}. Thank you!"),
    "donation_delivery_rescheduled": ("Delivery date changed", "Donation #{batch_no} will now go to {barangay} on {date}. {reason}"),
    "donation_delivery_returned": ("Delivery delayed", "Donation #{batch_no} went back to the CSWS office: {reason}. A new date will follow."),
    "donation_delivery_cancelled": ("Delivery cancelled", "The delivery of donation #{batch_no} was cancelled: {reason}. It will go on a later delivery."),
    # Donation expiry / cancellation (services/donations/donation_expiry.py)
    "donation_expiring_soon": ("Donation due soon", "Please hand over donation {batch_no} by {date}, or it will expire."),
    "donation_expired": ("Donation expired", "Donation {batch_no} expired because it was not handed over in time. Contact CSWS if you still want to give it."),
    "donation_cancelled": ("Donation cancelled", "Donation {batch_no} was cancelled. {reason}"),
    "donation_reinstated": ("Donation reopened", "Donation {batch_no} is active again. Please hand it over by {date}."),
    # Logistics
    "logistics_requested": ("Logistics requested", "CSWS requested transport for {title}."),
    "logistics_accepted": ("Logistics request accepted", "Request for {title} was accepted.{schedule}"),
    "logistics_scheduled": ("Logistics scheduled", "Pickup for {title}: {schedule}."),
    "logistics_declined": ("DRRMO declined transport", "DRRMO can't provide transport for {title}: {reason}. Ask DRRMO again or send it yourself."),
    "logistics_cancelled": ("Logistics request cancelled", "CSWS no longer needs transport for {title}: {reason}"),
    "logistics_completed": ("Logistics support completed", "DRRMO completed the support for {title}. {summary}"),
    "logistics_withdrawn": ("DRRMO can no longer help", "Transport for {title} was withdrawn: {reason}. Ask again or arrange another vehicle."),
    # Reminders (services/deliveries/delivery_reminders.py, every 5 minutes)
    "reminder_request_waiting": ("Request waiting for DRRMO", "The transport request for {title} has waited {hours}. Please accept or decline it."),
    "reminder_request_waiting_csws": ("DRRMO has not answered", "DRRMO has not answered the transport request for {title} in {hours}. Please call DRRMO to accept or decline it."),
    "reminder_in_transit_long": ("Still on the way", "{title} has been on the way for {hours}. Check with the driver, or use \"Truck came back\" if it returned."),
    "reminder_pickup_overdue": ("Pickup is late", "DRRMO was due to pick up {title} on {when}, but it is still being packed. Check with DRRMO, or reschedule it."),
    "reminder_not_confirmed": ("Not received yet", "{title} arrived at {barangay} {hours} ago, but the barangay has not confirmed receipt. Please follow up."),
    # Delivery
    "delivery_status_changed": ("Delivery update", "{title} is now: {status}."),
    "delivery_step_undone": ("Delivery step undone", "{title} is back to: {status}. {who} took back the last step."),
    "delivery_prepared": ("Aid is being prepared", "{title} for {barangay} is being prepared. Planned date: {date}."),
    "delivery_receipt_confirmed": ("Receipt confirmed", "The barangay confirmed receipt for {title}."),
    # J1 / NF-009: the barangay's count differs from what CSWS sent.
    "delivery_receipt_discrepancy": ("Received with differences", "{barangay} confirmed {title}, but the count differs from what was sent: {differences}."),
    "delivery_acknowledged": ("Aid acknowledged", "{barangay} acknowledged {title}. This is the final record of the delivery."),
    # Unexpected problems (api/v1/deliveries/delivery_problems.py)
    "delivery_rescheduled": ("Delivery date changed", "{title} is now set for {date}. {reason}"),
    "delivery_returned": ("Delivery delayed", "{title} went back to the CSWS office: {reason}. A new date will follow."),
    "delivery_cancelled": ("Delivery cancelled", "{title} was cancelled: {reason}"),
    # Accounts (callers also email these with core.notifications.email.send_email)
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
    # Live update after the commit (core/notifications/realtime.py); never fails the save.
    queue_push(db, user_id, event, entity_type, entity_id)
    # Push to the Android app after the commit (core/notifications/push.py); same rule.
    push.queue(db, user_id, event, n.title, n.message, entity_type, entity_id, n.notification_id)
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
    from models.accounts.role_model import Role  # local import avoids circular imports
    from models.accounts.user_rbac_model import User

    q = (
        db.query(User.user_id)
        .join(Role, Role.role_id == User.role_id)
        .filter(Role.role_name.in_(list(role_names)), User.is_active.is_(True))
    )
    if barangay_id is not None:
        q = q.filter(User.assigned_barangay_id == barangay_id)
    return [uid for (uid,) in q.all() if uid != exclude_user_id]


# Testing (Oct 23): DRRMO and CSWS Main Office share logistics notifications.
# Everyone on both teams hears what the other office did (asked, accepted,
# declined, completed, cancelled, withdrawn), not only the requester, so a
# request isn't missed when that one person is away.
LOGISTICS_TEAM_ROLES = ("CSWS Main Office", "DRRMO Logistics Support")


def logistics_team_ids(db: Session, *also: Optional[int],
                       exclude_user_id: Optional[int] = None) -> set[int]:
    """Both logistics teams, plus [also] (e.g. a Disaster Unit requester),
    minus whoever did the action."""
    ids = set(user_ids_with_role(db, LOGISTICS_TEAM_ROLES)) | {u for u in also if u}
    ids.discard(exclude_user_id)
    return ids
