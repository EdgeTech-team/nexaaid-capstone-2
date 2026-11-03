"""Response times for the CSWS and DRRMO dashboards (Phase 7, Scope 7.5,
Table 36 / Table 37), read from the audit log; no new tables.

  * request -> accepted: when CSWS asked DRRMO for transport (the request's
    created_at) until DRRMO accepted it (ACCEPT LOGISTICS REQUEST).
  * On the way -> Arrived: from a delivery's move to In Transit until its
    next move to Delivered (UPDATE DELIVERY STATUS rows). A truck that came
    back starts the clock again when it leaves the next time.
"""
from datetime import datetime, timedelta, timezone
from typing import Optional

from sqlalchemy import and_
from sqlalchemy.orm import Session

from models.audit_log_model import AuditLog
from models.logistics_request_model import LogisticsRequest
from services.donation_expiry import utc

DAYS = 30   # the figures cover the last 30 days


def _avg(minutes: list) -> Optional[int]:
    return round(sum(minutes) / len(minutes)) if minutes else None


def response_times(db: Session, now: Optional[datetime] = None, days: int = DAYS) -> dict:
    now = utc(now) if now else datetime.now(timezone.utc)
    since = now - timedelta(days=days)

    accepted = (db.query(LogisticsRequest.created_at, AuditLog.timestamp)
                .join(AuditLog, and_(AuditLog.entity_type == "logistics_requests",
                                     AuditLog.entity_id == LogisticsRequest.request_id,
                                     AuditLog.action == "ACCEPT LOGISTICS REQUEST"))
                .filter(LogisticsRequest.created_at >= since).all())
    waits = [(utc(at) - utc(asked)).total_seconds() / 60
             for asked, at in accepted if utc(at) >= utc(asked)]

    left, trips = {}, []
    for delivery_id, new, at in (
            db.query(AuditLog.entity_id, AuditLog.new_value, AuditLog.timestamp)
            .filter(AuditLog.entity_type == "deliveries",
                    AuditLog.action == "UPDATE DELIVERY STATUS",
                    AuditLog.timestamp >= since)
            .order_by(AuditLog.log_id)):
        status = (new or {}).get("status")
        if status == "In Transit":
            left[delivery_id] = utc(at)
        elif status == "Delivered" and delivery_id in left:
            trips.append((utc(at) - left.pop(delivery_id)).total_seconds() / 60)

    return {"days": days,
            "accept_minutes": _avg(waits), "accepted": len(waits),
            "trip_minutes": _avg(trips), "trips": len(trips)}
