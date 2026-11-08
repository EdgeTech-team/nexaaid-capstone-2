"""Reminders for the CSWS Main Office <-> DRRMO delivery flow (Scope 7.5,
Table 36 Logistics Support Coordination, Table 37 Delivery Tracking).
No schema change: reminders are ordinary notifications, and the
notifications table itself shows whether one was already sent.

  * A logistics request still Pending after 1 h: every DRRMO user. After
    3 h also every CSWS Main Office user (and the requester).
  * A delivery On the way (In Transit) for 24 h: CSWS Main Office and the
    DRRMO user carrying it.
  * DRRMO's pickup time passed while the goods are still Being packed: the
    DRRMO user who accepted it and CSWS Main Office.
  * Arrived (Delivered) but not Received by barangay (Confirmed) after 24 h:
    CSWS Main Office, so they follow up with the barangay.

The same reminder about the same thing reaches a person at most once per
REPEAT_WINDOW. run_reminders(db, now) does one pass and takes "now", so
tests freeze the time; start_reminder_loop() runs it every 5 minutes in the
server (main.py).
"""
import asyncio
import logging
import os
from datetime import datetime, timedelta, timezone
from typing import Iterable, Optional

from sqlalchemy.orm import Session

from core.notifications import notify_event_many, user_ids_with_role
from models.audit_log_model import AuditLog
from models.barangay_model import Barangay
from models.delivery import Delivery
from models.logistics_request_model import LogisticsRequest
from models.notification import Notification
from services.donation_expiry import utc

log = logging.getLogger("uvicorn.error")

MAIN_OFFICE = "CSWS Main Office"
DRRMO = "DRRMO Logistics Support"

# Thresholds (Phase 5). Change here only.
PENDING_DRRMO_AFTER = timedelta(hours=1)
PENDING_CSWS_AFTER = timedelta(hours=3)
IN_TRANSIT_AFTER = timedelta(hours=24)
PICKUP_LATE_AFTER = timedelta(minutes=30)   # a little slack after DRRMO's time
NOT_CONFIRMED_AFTER = timedelta(hours=24)
REPEAT_WINDOW = timedelta(hours=12)         # the same reminder, at most this often
EVERY = timedelta(minutes=5)                # how often the loop runs
FIRST_RUN_AFTER = timedelta(minutes=1)      # let the server finish starting


def _ago(delta: timedelta) -> str:
    hours = int(delta.total_seconds() // 3600)
    if hours >= 48:
        return f"{hours // 24} days"
    if hours >= 24:
        return "1 day"
    return "1 hour" if hours == 1 else f"{max(hours, 1)} hours"


def _remind(db: Session, user_ids: Iterable[int], event: str, entity_type: str,
            entity_id: int, now: datetime, **ctx) -> int:
    """Notify those of user_ids who did not get this reminder about this
    entity within REPEAT_WINDOW. Returns how many were notified."""
    wanted = {u for u in user_ids if u}
    if not wanted:
        return 0
    already = {uid for (uid,) in db.query(Notification.user_id).filter(
        Notification.type == event,
        Notification.entity_type == entity_type,
        Notification.entity_id == entity_id,
        Notification.user_id.in_(wanted),
        Notification.sent_at >= now - REPEAT_WINDOW,
    ).all()}
    return notify_event_many(db, wanted - already, event, entity_type, entity_id, **ctx)


def reached_at(db: Session, delivery_ids: list, status: str) -> dict:
    """delivery_id -> when it last moved to status (audit log, UC-CM2)."""
    if not delivery_ids:
        return {}
    rows = (db.query(AuditLog.entity_id, AuditLog.new_value, AuditLog.timestamp)
            .filter(AuditLog.entity_type == "deliveries",
                    AuditLog.entity_id.in_(delivery_ids),
                    AuditLog.action == "UPDATE DELIVERY STATUS")
            .order_by(AuditLog.log_id).all())
    out = {}
    for delivery_id, new, at in rows:
        if (new or {}).get("status") == status:
            out[delivery_id] = utc(at)
    return out


def _carrier(db: Session, delivery_id: int) -> set:
    from api.v1.drrmo_router import drrmo_to_tell   # routers import services
    return drrmo_to_tell(db, delivery_id)


def run_reminders(db: Session, now: Optional[datetime] = None) -> dict:
    """One pass. Adds notifications (does not commit). Returns how many
    people each kind of reminder reached."""
    from api.v1.drrmo_router import nice_time
    now = utc(now) if now else datetime.now(timezone.utc)
    csws = set(user_ids_with_role(db, [MAIN_OFFICE]))
    sent = {"request_waiting": 0, "request_waiting_csws": 0, "in_transit_long": 0,
            "pickup_overdue": 0, "not_confirmed": 0}

    # Requests DRRMO has not answered.
    drrmo = set(user_ids_with_role(db, [DRRMO]))
    for req in db.query(LogisticsRequest).filter(LogisticsRequest.status == "Pending").all():
        waited = now - utc(req.created_at)
        if waited >= PENDING_DRRMO_AFTER:
            sent["request_waiting"] += _remind(
                db, drrmo, "reminder_request_waiting", "logistics_request", req.request_id,
                now, title=req.title, hours=_ago(waited))
        if waited >= PENDING_CSWS_AFTER:
            sent["request_waiting_csws"] += _remind(
                db, csws | {req.requested_by_user_id}, "reminder_request_waiting_csws",
                "logistics_request", req.request_id, now, title=req.title, hours=_ago(waited))

    live = (db.query(Delivery)
            .filter(Delivery.deleted_at.is_(None),
                    Delivery.status.in_(("Preparing", "In Transit", "Delivered"))).all())
    names = {b.barangay_id: b.barangay_name for b in db.query(Barangay).filter(
        Barangay.barangay_id.in_({d.destination_barangay_id for d in live} or {-1})).all()}

    # On the way for too long.
    on_road = [d for d in live if d.status == "In Transit"]
    since = reached_at(db, [d.delivery_id for d in on_road], "In Transit")
    for d in on_road:
        if d.delivery_id in since and now - since[d.delivery_id] >= IN_TRANSIT_AFTER:
            sent["in_transit_long"] += _remind(
                db, csws | _carrier(db, d.delivery_id), "reminder_in_transit_long", "delivery",
                d.delivery_id, now, title=f"Delivery #{d.delivery_id}",
                hours=_ago(now - since[d.delivery_id]))

    # DRRMO's pickup time passed, goods still being packed.
    packing = {d.delivery_id: d for d in live if d.status == "Preparing"}
    if packing:
        for req in db.query(LogisticsRequest).filter(
                LogisticsRequest.status == "Accepted",
                LogisticsRequest.delivery_id.in_(list(packing))).all():
            d = packing[req.delivery_id]
            due = utc(req.scheduled_date or d.delivery_date)
            if due is not None and now - due >= PICKUP_LATE_AFTER:
                sent["pickup_overdue"] += _remind(
                    db, csws | {req.assigned_to_user_id}, "reminder_pickup_overdue", "delivery",
                    d.delivery_id, now, title=f"Delivery #{d.delivery_id}", when=nice_time(due))

    # Arrived, but the barangay has not confirmed receipt.
    arrived = [d for d in live if d.status == "Delivered"]
    since = reached_at(db, [d.delivery_id for d in arrived], "Delivered")
    for d in arrived:
        if d.delivery_id in since and now - since[d.delivery_id] >= NOT_CONFIRMED_AFTER:
            sent["not_confirmed"] += _remind(
                db, csws, "reminder_not_confirmed", "delivery", d.delivery_id, now,
                title=f"Delivery #{d.delivery_id}",
                barangay=names.get(d.destination_barangay_id, "the barangay"),
                hours=_ago(now - since[d.delivery_id]))
    return sent


def _one_pass() -> None:
    from core import database
    db = database.SessionLocal()
    try:
        sent = run_reminders(db)
        db.commit()
        if any(sent.values()):
            log.info("reminders sent: %s", sent)
    except Exception:  # noqa: BLE001 - a failed pass must not stop the next one
        db.rollback()
        log.exception("reminders: pass failed")
    finally:
        db.close()


async def reminder_loop() -> None:
    """Every EVERY, one pass in a worker thread (the database calls are
    blocking, so the event loop keeps serving requests meanwhile).

    Why a plain asyncio loop and not a scheduler library: one job every five
    minutes needs no new dependency, and NexaAid runs as a single server
    instance. With several instances each would run the pass; the
    REPEAT_WINDOW check keeps people from being told twice in most cases."""
    await asyncio.sleep(FIRST_RUN_AFTER.total_seconds())
    while True:
        await asyncio.to_thread(_one_pass)
        await asyncio.sleep(EVERY.total_seconds())


def reminders_enabled() -> bool:
    """REMINDERS=off in the environment stops the loop (e.g. a laptop that
    points at the shared database while someone else's server runs)."""
    return os.getenv("REMINDERS", "on").strip().lower() not in ("off", "0", "false", "no")
