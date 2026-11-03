# Manuscript UC-DR1 / UC-DR2 and the Logistics Support Coordination Module.
from datetime import datetime, timezone
from typing import Optional

from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel, Field
from sqlalchemy.orm import Session

from core.database import get_db
from core.auth import require_role
from core.audit import log_action
from models.user_rbac_model import User
from models.logistics_request_model import LogisticsRequest
from models.delivery import Delivery
from models.item_model import Item
from models.report import DisasterReport, DisasterType, Barangay
from models.physical_donation_model import PhysicalDonation
from services.donation_expiry import entry_status, utc
from core.notifications import logistics_team_ids, notify_event_many, user_ids_with_role
from schemas.physical_donation_schema import MANILA
from core.notifications import notify_event
from schemas.logistics_request_schema import (
    AcceptLogisticsRequest, DeclineLogisticsRequest, LogisticsRequestResponse
)

router = APIRouter(prefix="/drrmo", tags=["drrmo"])

DRRMO = "DRRMO Logistics Support"

# 3.11 levels, most urgent first. Reports the engine couldn't score
# ("Needs Review" is stored as NULL) go last.
PRIORITY_RANK = {"Critical": 0, "High": 1, "Medium": 2, "Low": 3}


def priority_sort_key(row: dict):
    """Most urgent report first. Within the same level, the oldest request first."""
    return (PRIORITY_RANK.get(row.get("priority_level"), len(PRIORITY_RANK)), row["request_id"])


# ---------------------------------------------------------------------------
# Scheduling (Nov 2026, back to the manuscript: UC-DR1 step 5, Scope 5.3
# item 3, Appendix H 7.4; replaces testing fix 7.4). Main Office plans the
# delivery date it asks DRRMO for; DRRMO accepts with its own date and time
# (Table 36 alt 4a) and the delivery date follows it. Main Office can still
# reschedule (POST /deliveries/{id}/reschedule). A pickup run's schedule is
# its pickup day.
#
# Completion (testing fix 7.5, Nov 2026): DRRMO's support ends when the goods
# arrive. Marking the delivery Delivered completes the request by itself
# (complete_on_arrival); PATCH /complete stays for pickup runs and older
# requests, not before the scheduled date or the goods' arrival. The
# barangay's receipt (Confirmed) is the barangay's own step.
# ---------------------------------------------------------------------------

# Delivery statuses from Module 8 (deliveries.py). If 8.1 / 8.2 rename them,
# change them here only.
_LEFT_THE_OFFICE = ("In Transit", "Delivered", "Confirmed")   # 8.1 done


# Note lines DRRMO adds when accepting (UC-DR1 step 5), read back by request_rows.
VEHICLE = "DRRMO vehicle: "
DRIVER = "DRRMO driver: "


def nice_time(value) -> str:
    """'Fri, Oct 23 · 2:00 PM' in Philippine time, for notices and summaries."""
    v = utc(value)
    if v is None:
        return ""
    return (v.astimezone(MANILA).strftime("%a, %b %d · %I:%M %p")
            .replace(" 0", " "))


# UC-CM2 alt 3a: a Pending or Accepted request holds the delivery for DRRMO.
# Declined and Cancelled requests no longer involve DRRMO.
OPEN = ("Pending", "Accepted")


def open_request_for(db: Session, delivery_id: int) -> Optional[LogisticsRequest]:
    """The DRRMO request this delivery waits on (Pending) or travels with (Accepted)."""
    return (db.query(LogisticsRequest)
            .filter(LogisticsRequest.delivery_id == delivery_id,
                    LogisticsRequest.status.in_(OPEN))
            .order_by(LogisticsRequest.request_id.desc()).first())


def drrmo_to_tell(db: Session, delivery_id: int) -> set:
    """Table 36: DRRMO hears about a delivery only when it is involved.
    Pending: every DRRMO user (any of them may accept). Accepted or Completed:
    only the DRRMO user who accepted it. No request, or only Declined /
    Cancelled ones: nobody."""
    req = (db.query(LogisticsRequest)
           .filter(LogisticsRequest.delivery_id == delivery_id,
                   LogisticsRequest.status.in_(OPEN + ("Completed",)))
           .order_by(LogisticsRequest.request_id.desc()).first())
    if req is None:
        return set()
    if req.status == "Pending":
        return set(user_ids_with_role(db, [DRRMO]))
    return {req.assigned_to_user_id} if req.assigned_to_user_id else set()


def note_line(notes: Optional[str], *prefixes: str) -> Optional[str]:
    """The newest note line starting with one of prefixes, without the prefix."""
    for line in reversed((notes or "").splitlines()):
        for p in prefixes:
            if line.startswith(p):
                return line[len(p):].strip() or None
    return None


def _reason(req: LogisticsRequest) -> Optional[str]:
    """Why a request was declined, withdrawn or cancelled (None otherwise)."""
    if req.status == "Declined":
        # Requests declined before Nov 2026 kept only the reason in notes.
        legacy = req.notes if req.notes and "\n" not in req.notes and not req.notes.startswith("Needs ") else None
        return note_line(req.notes, "Declined by DRRMO:", "Withdrawn by DRRMO:") or legacy
    if req.status == "Cancelled":
        return note_line(req.notes, "Cancelled by CSWS:", "Cancelled by Disaster Unit:")
    return None


def _manila_day(value):
    """Calendar day in Mandaue of a date or datetime (naive = UTC)."""
    if value is None:
        return None
    if isinstance(value, datetime):
        if value.tzinfo is None:
            value = value.replace(tzinfo=timezone.utc)
        return value.astimezone(MANILA).date()
    return value  # already a date (pickup_date)


def schedule_of(req: LogisticsRequest, delivery: Optional[Delivery]):
    """7.4: the date Main Office set for this support."""
    if req.request_type == "Pickup":
        return req.pickup_date
    if delivery is not None:
        return delivery.delivery_date
    return req.scheduled_date


def completion_blocker(req: LogisticsRequest, delivery: Optional[Delivery], now=None) -> Optional[str]:
    """7.5: why DRRMO cannot mark this request completed yet (None = it can).
    Nov 2026 (Table 36): DRRMO's part ends when the goods arrive; the
    barangay's receipt is its own step, so it no longer holds the request."""
    if req.status != "Accepted":
        return "Only accepted requests can be completed."
    today = _manila_day(now or datetime.now(timezone.utc))
    day = _manila_day(schedule_of(req, delivery))
    if day is not None and today < day:
        return f"Wait for the scheduled date ({day:%b %d, %Y})."
    if req.request_type == "Pickup":
        return None
    if delivery is None:
        return "The delivery for this request no longer exists."
    if delivery.status == "Cancelled":
        return "CSWS Main Office cancelled this delivery."
    if delivery.status not in _LEFT_THE_OFFICE:
        # Advisor (Oct 24): DRRMO marks it In Transit when it picks up the goods.
        return "Pick up the goods first (Picked up · mark In Transit, on the way)."
    if delivery.status == "In Transit":
        return "Mark it Delivered (arrived) when you reach the barangay."
    return None


def _pickup_stops(db: Session, requests) -> dict:
    """request_id -> the Door to Door stops of a pickup run, in stop order.
    DRRMO gets where to go and what to load, not the donor's name or number
    (CSWS Disaster Unit coordinates with the donors)."""
    refs = {ref for r in requests if r.request_type == "Pickup" for ref in r.batch_list}
    if not refs:
        return {}
    rows = (db.query(PhysicalDonation)
            .filter(PhysicalDonation.batch_reference.in_(refs))
            .order_by(PhysicalDonation.donation_id).all())
    items = {i.item_id: i for i in db.query(Item).filter(
        Item.item_id.in_({r.item_id for r in rows} or {-1})).all()}
    by_ref: dict = {}
    for row in rows:
        by_ref.setdefault(row.batch_reference, []).append(row)
    out = {}
    for r in requests:
        if r.request_type != "Pickup":
            continue
        stops = []
        for n, ref in enumerate(r.batch_list, start=1):
            lines = by_ref.get(ref, [])
            first = lines[0] if lines else None
            stops.append({
                "stop": n,
                "batch_reference": ref,
                "landmark": first.pickup_landmark if first else None,
                "address": first.pickup_address if first else None,
                "lat": float(first.pickup_lat) if first and first.pickup_lat is not None else None,
                "lng": float(first.pickup_lng) if first and first.pickup_lng is not None else None,
                "report_id": first.report_id if first else None,
                "status": entry_status({l.status for l in lines}) if lines else "Unknown",
                "goods": [
                    f"{l.quantity} {items[l.item_id].unit_of_measure} {items[l.item_id].item_name}"
                    if l.item_id in items else f"{l.quantity} item(s)"
                    for l in lines
                ],
            })
        out[r.request_id] = stops
    return out


def request_rows(db: Session, requests) -> list:
    """Requests with their delivery (or pickup run) details, used by DRRMO,
    CSWS Main Office and Disaster Unit screens."""
    deliveries = {
        d.delivery_id: d
        for d in db.query(Delivery).filter(
            Delivery.delivery_id.in_([r.delivery_id for r in requests if r.delivery_id] or [-1])
        ).all()
    }
    pickup_stops = _pickup_stops(db, requests)
    items = {i.item_id: i for i in db.query(Item).all()}
    types = {t.disaster_type_id: t.type_name for t in db.query(DisasterType).all()}
    brgys = {b.barangay_id: b.barangay_name for b in db.query(Barangay).all()}
    report_ids = {d.report_id for d in deliveries.values()}
    report_ids |= {s["report_id"] for stops in pickup_stops.values() for s in stops if s["report_id"]}
    reports = {r.report_id: r for r in db.query(DisasterReport).filter(
        DisasterReport.report_id.in_(report_ids or [-1])).all()}
    requesters = {u.user_id: u for u in db.query(User).filter(
        User.user_id.in_({r.requested_by_user_id for r in requests}
                         | {r.assigned_to_user_id for r in requests if r.assigned_to_user_id}
                         or {-1})).all()}
    out = []
    for r in requests:
        d = deliveries.get(r.delivery_id) if r.delivery_id else None
        stops = pickup_stops.get(r.request_id, [])
        if r.request_type == "Pickup":
            # The most urgent report among the stops decides the priority.
            linked = [reports[s["report_id"]] for s in stops if s["report_id"] in reports]
            rep = min(linked, key=lambda x: PRIORITY_RANK.get(x.priority_level, len(PRIORITY_RANK)),
                      default=None)
        else:
            rep = reports.get(d.report_id) if d else None
        stage = r.status
        if r.status == "Accepted" and d is not None and d.status in _LEFT_THE_OFFICE:
            # UC-DR2: in-transit support, from the delivery's tracking status.
            # It stays here after the barangay confirms receipt, until DRRMO
            # marks it completed (7.5), instead of jumping back to Accepted.
            stage = "In Transit"
        who = requesters.get(r.requested_by_user_id)
        driver = requesters.get(r.assigned_to_user_id) if r.assigned_to_user_id else None
        landmarks = []
        for s in stops:
            if s["landmark"] and s["landmark"] not in landmarks:
                landmarks.append(s["landmark"])
        out.append({
            "request_id": r.request_id,
            "request_type": r.request_type or "Delivery",
            "delivery_id": r.delivery_id,
            "status": r.status,
            "stage": stage,
            # The delivery date (or pickup day), so a reschedule shows up here
            # right away. Main Office plans it; once DRRMO accepted a delivery
            # request it is DRRMO's time (UC-DR1 step 5, Table 36 alt 4a).
            "scheduled_date": schedule_of(r, d),
            "scheduled_by": ("DRRMO" if r.request_type != "Pickup" and r.scheduled_date is not None
                             and r.status in ("Accepted", "Completed") else "CSWS Main Office"),
            "vehicle": note_line(r.notes, VEHICLE),
            "driver": note_line(r.notes, DRIVER),
            # 7.5: the app greys out "Mark completed" and shows this reason.
            "can_complete": r.status == "Accepted" and completion_blocker(r, d) is None,
            "complete_blocker": completion_blocker(r, d) if r.status == "Accepted" else None,
            "notes": r.notes,
            # 7.2: what is needed, on its own line for the request card.
            "needs": next((line for line in (r.notes or "").splitlines()
                           if line.startswith("Needs ")), None),
            "created_at": r.created_at,
            "requested_by": f"{who.first_name} {who.last_name}".strip() if who else None,
            "requested_by_role": who.role.role_name if who and who.role else None,
            # The DRRMO user who accepted (or declined) it; only they move the delivery.
            "assigned_to_user_id": r.assigned_to_user_id,
            "assigned_to": f"{driver.first_name} {driver.last_name}".strip() if driver else None,
            # Table 36 alt 3a: why DRRMO said no, for the CSWS card ("Ask DRRMO again").
            "reason": _reason(r),
            "pickup_date": r.pickup_date.isoformat() if r.pickup_date else None,
            "stops": stops,
            "delivery_status": d.status if d else None,
            "destination": (
                (brgys.get(d.destination_barangay_id) if d else None) if r.request_type != "Pickup"
                else f"{len(stops)} Door to Door stop{'s' if len(stops) != 1 else ''}"
                     + (f" near {', '.join(landmarks[:3])}" if landmarks else "")
            ),
            "report_label": (
                r.title[0].upper() + r.title[1:] if r.request_type == "Pickup"
                else (f"#{rep.report_id} {types.get(rep.disaster_type_id, 'Disaster')} - "
                      f"{brgys.get(rep.barangay_id, 'Barangay')}") if rep else None
            ),
            "report_id": rep.report_id if rep else None,
            "priority_level": rep.priority_level if rep else None,
            "ai_priority_score": (float(rep.ai_priority_score)
                                  if rep and rep.ai_priority_score is not None else None),
            "goods": (
                [g for s in stops for g in s["goods"]] if r.request_type == "Pickup" else [
                    f"{i.quantity} {items[i.item_id].unit_of_measure} {items[i.item_id].item_name}"
                    if i.item_id in items else f"{i.quantity} item(s)"
                    for i in (d.items if d else [])
                ]
            ),
        })
    return out


@router.get("/requests")
def list_requests(
    status: Optional[str] = Query(default=None, description="Pending / Accepted / Declined / Completed"),
    priority_level: Optional[str] = Query(default=None, description="Critical / High / Medium / Low"),
    db: Session = Depends(get_db),
    current_user: User = Depends(require_role(DRRMO)),
):
    """UC-DR1 step 1: DRRMO sees requests ordered by the linked report's
    3.11 priority, so the most urgent deliveries get scheduled first."""
    query = db.query(LogisticsRequest)
    if status:
        query = query.filter(LogisticsRequest.status == status)
    rows = request_rows(db, query.all())
    for r in rows:
        # Table 36: only the DRRMO user who accepted it moves the delivery.
        r["mine"] = r["assigned_to_user_id"] == current_user.user_id
    if priority_level:
        rows = [r for r in rows if r["priority_level"] == priority_level]
    return sorted(rows, key=priority_sort_key)


@router.patch("/requests/{request_id}/accept", response_model=LogisticsRequestResponse)
def accept_request(
    request_id: int,
    payload: AcceptLogisticsRequest,
    db: Session = Depends(get_db),
    current_user: User = Depends(require_role(DRRMO)),
):
    req = db.query(LogisticsRequest).filter(LogisticsRequest.request_id == request_id).first()
    if req is None:
        raise HTTPException(status_code=404, detail="Logistics request not found")
    if req.status != "Pending":
        raise HTTPException(status_code=400, detail=f"Request is already {req.status}, cannot accept")

    # UC-DR1 step 5 / Table 36 alt 4a: DRRMO says when its truck comes.
    # Pickup runs keep the Disaster Unit's pickup day.
    when = payload.scheduled_date
    if req.request_type != "Pickup" and when is None:
        raise HTTPException(status_code=422,
                            detail="Choose the date and time DRRMO will pick up the goods.")

    req.status = "Accepted"
    req.assigned_to_user_id = current_user.user_id
    # Keep what CSWS asked for; DRRMO's details go on their own lines.
    added = [f"{label}{value}" for label, value in (
        (VEHICLE, payload.vehicle), (DRIVER, payload.driver), ("DRRMO: ", payload.notes)) if value]
    if added:
        req.notes = "\n".join(([req.notes] if req.notes else []) + added)
    log_action(db, current_user, "ACCEPT LOGISTICS REQUEST", "logistics_requests", request_id,
               old={"status": "Pending"},
               new={"status": "Accepted", "scheduled_date": when.isoformat() if when else None,
                    "vehicle": payload.vehicle, "driver": payload.driver})
    schedule = ""
    if when is not None:
        req.scheduled_date = when
        d = db.get(Delivery, req.delivery_id) if req.delivery_id else None
        # One date everywhere: the delivery follows DRRMO's time, so "can't
        # leave before its date", the barangay's and donors' notices and later
        # CSWS reschedules all use the same date (delivery_problems._reschedule
        # logs it, tells the barangay and the donors).
        if d is not None and utc(d.delivery_date) != when:
            from api.v1.delivery_problems import _reschedule
            _reschedule(db, d, when, "Scheduled by DRRMO", current_user)
        schedule = f" DRRMO comes {nice_time(when)}."
    notify_event_many(db, logistics_team_ids(db, req.requested_by_user_id,
                                             exclude_user_id=current_user.user_id),
                      "logistics_accepted", "logistics_request", request_id,
                      title=req.title, schedule=schedule)

    db.commit()
    db.refresh(req)
    return req


@router.patch("/requests/{request_id}/decline", response_model=LogisticsRequestResponse)
def decline_request(
    request_id: int,
    payload: DeclineLogisticsRequest,
    db: Session = Depends(get_db),
    current_user: User = Depends(require_role(DRRMO)),
):
    req = db.query(LogisticsRequest).filter(LogisticsRequest.request_id == request_id).first()
    if req is None:
        raise HTTPException(status_code=404, detail="Logistics request not found")
    if req.status != "Pending":
        raise HTTPException(status_code=400, detail=f"Request is already {req.status}, cannot decline")

    req.status = "Declined"
    req.assigned_to_user_id = current_user.user_id
    # Keep what CSWS asked for ("Needs ..."), so "Ask DRRMO again" can reuse it.
    reason = f"Declined by DRRMO: {payload.notes}"
    req.notes = f"{req.notes}\n{reason}" if req.notes else reason
    log_action(db, current_user, "DECLINE LOGISTICS REQUEST", "logistics_requests", request_id,
               old={"status": "Pending"}, new={"status": "Declined", "reason": payload.notes})
    # Table 36 alt 3a: every CSWS Main Office user hears (logistics_team_ids),
    # not only the requester, so someone can ask again or send it.
    notify_event_many(db, logistics_team_ids(db, req.requested_by_user_id,
                                             exclude_user_id=current_user.user_id),
                      "logistics_declined", "logistics_request", request_id,
                      title=req.title, reason=payload.notes or "")

    db.commit()
    db.refresh(req)
    return req


@router.post("/requests/{request_id}/picked-up")
def picked_up(
    request_id: int,
    db: Session = Depends(get_db),
    current_user: User = Depends(require_role(DRRMO, "admin")),
):
    """Advisor (Oct 24): DRRMO picked up the prepared goods from CSWS, so the
    delivery goes In Transit (same history and notifications as CSWS
    advancing it). Only the DRRMO user who accepted the request, or the
    Administrator (Table 36)."""
    return _move_own_delivery(db, request_id, current_user, "Preparing")


@router.post("/requests/{request_id}/delivered")
def delivered(
    request_id: int,
    db: Session = Depends(get_db),
    current_user: User = Depends(require_role(DRRMO, "admin")),
):
    """Testing (Oct 27): DRRMO, who carried the goods, marks the delivery
    Delivered at the barangay, which also completes the request (Table 36).
    The barangay rep then confirms receipt."""
    return _move_own_delivery(db, request_id, current_user, "In Transit")


def _move_own_delivery(db: Session, request_id: int, current_user, from_status: str) -> dict:
    """One step forward for the delivery of DRRMO's accepted request.
    move_to_next_status checks that the user is the DRRMO user who accepted
    it or the Administrator (Table 36 / Table 37)."""
    from api.v1.deliveries import move_to_next_status  # deliveries imports this module

    req = db.get(LogisticsRequest, request_id)
    if req is None:
        raise HTTPException(status_code=404, detail="Logistics request not found")
    if req.status == "Completed":
        raise HTTPException(status_code=409, detail="This request is already completed.")
    if req.status != "Accepted":
        raise HTTPException(status_code=409, detail="Accept the request first.")
    d = db.get(Delivery, req.delivery_id) if req.delivery_id else None
    if d is None:
        raise HTTPException(status_code=409, detail="This request has no delivery to move.")
    if d.status != from_status:
        raise HTTPException(status_code=409, detail=f"Delivery #{d.delivery_id} is {d.status}.")
    move_to_next_status(db, d, current_user)
    db.commit()
    return request_rows(db, [req])[0]


class CompleteLogisticsRequest(BaseModel):
    """Logistics assistance summary (module step: date completed, goods
    transported, destination). Alt 6a: required before saving as completed."""
    summary: str = Field(..., min_length=3, max_length=1000)
    completed_at: Optional[datetime] = None


@router.patch("/requests/{request_id}/complete")
def complete_request(
    request_id: int,
    payload: CompleteLogisticsRequest,
    db: Session = Depends(get_db),
    current_user: User = Depends(require_role(DRRMO)),
):
    """Edge cases only (pickup runs, requests accepted before Nov 2026):
    a delivery request completes by itself when DRRMO marks it Delivered."""
    req = db.get(LogisticsRequest, request_id)
    if req is None:
        raise HTTPException(status_code=404, detail="Logistics request not found")
    if req.status != "Accepted":
        raise HTTPException(status_code=400, detail="Only accepted (scheduled) requests can be completed")
    # 7.5: not before the date, nor before the goods reached the barangay.
    delivery = db.get(Delivery, req.delivery_id) if req.delivery_id else None
    blocker = completion_blocker(req, delivery)
    if blocker:
        raise HTTPException(status_code=409, detail=blocker)
    record_completion(db, req, current_user, payload.summary, payload.completed_at)
    db.flush()
    return request_rows(db, [req])[0]


def record_completion(db: Session, req: LogisticsRequest, user, summary: str,
                      completed_at: Optional[datetime] = None) -> set:
    """Table 36: the logistics assistance summary (date completed, goods
    transported, destination) closes the request. Used by PATCH /complete and
    when DRRMO marks the delivery Delivered. Returns who was notified."""
    row = request_rows(db, [req])[0]
    done = completed_at or datetime.now(timezone.utc)
    text = (f"Completed {done:%Y-%m-%d}: {summary}. "
            f"Goods: {', '.join(row['goods']) or '-'}. Destination: {row['destination'] or '-'}.")
    req.status = "Completed"
    req.notes = f"{req.notes}\n{text}" if req.notes else text
    log_action(db, user, "COMPLETE LOGISTICS SUPPORT", "logistics_requests", req.request_id,
               old={"status": "Accepted"}, new={"status": "Completed", "summary": text})
    # Oct 17 run-through: CSWS hears that the support is done, as it does
    # when DRRMO accepts or declines (shared logistics notifications).
    told = logistics_team_ids(db, req.requested_by_user_id, exclude_user_id=user.user_id)
    notify_event_many(db, told, "logistics_completed", "logistics_request", req.request_id,
                      title=req.title, summary=summary)
    return told


def complete_on_arrival(db: Session, req: LogisticsRequest, user) -> set:
    """Table 36 / Table 37: the goods reached the barangay, so DRRMO's
    support is done. The summary is built from who carried it, with what and
    when (record_completion adds goods and destination). The barangay's
    receipt (Confirmed) stays its own step. Returns who was notified."""
    driver = db.get(User, req.assigned_to_user_id) if req.assigned_to_user_id else None
    name = f"{driver.first_name or ''} {driver.last_name or ''}".strip() if driver else ""
    vehicle = note_line(req.notes, VEHICLE)
    summary = (f"Goods arrived {nice_time(datetime.now(timezone.utc))}, carried by DRRMO"
               + (f" ({name})" if name else "") + (f" with {vehicle}" if vehicle else ""))
    return record_completion(db, req, user, summary)


@router.get("/dashboard")
def drrmo_dashboard(
    db: Session = Depends(get_db),
    current_user: User = Depends(require_role(DRRMO)),
):
    rows = request_rows(db, db.query(LogisticsRequest).all())
    return {
        "total_requests": len(rows),
        "pending_requests": sum(1 for r in rows if r["stage"] == "Pending"),
        "scheduled": sum(1 for r in rows if r["stage"] == "Accepted"),
        "in_transit": sum(1 for r in rows if r["stage"] == "In Transit"),
        "completed": sum(1 for r in rows if r["stage"] == "Completed"),
        "declined": sum(1 for r in rows if r["stage"] == "Declined"),
    }