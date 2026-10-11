"""Door to Door pickup plan for CSWS Main Office (Oct 12 notes, pickup
logic v2; manuscript UC-D2 alt 7c and UC-CM1 for Door to Door).

GET  /donations/pickup-plan?vehicle=van
     Waiting Door to Door donations grouped into stops (same landmark AND a
     shared day), each with an estimated size, planned on a date in the next
     two weeks, in a one-way order from the CSWS office. Decision support
     only: CSWS confirms the run (manuscript: the system suggests, staff
     decide). Donations without a usable pin come back in "follow_up".

POST /donations/pickup-plan/not-home
     The picker found nobody home. The stop moves to the donor's next
     allowed day after that date. The donor (if registered) is told.

"Mark picked up" is the existing receiving flow (scan the QR / open the
entry): the picker's count is saved in received_goods.actual_quantity,
separate from what the donor declared (manuscript limitation 3).

Same roles as GET /donations/pickups: CSWS Main Office and Administrator.
Donors, DRRMO and the Disaster Unit get 403.
"""
from datetime import date, datetime, timezone
from typing import List, Optional

from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel, Field
from sqlalchemy.orm import Session

from core.audit import log_action
from core.auth import require_role
from core.database import get_db
from core.notifications import notify
from models.item_model import Item
from models.logistics_request_model import LogisticsRequest
from models.physical_donation_model import PhysicalDonation
from models.report import DisasterReport
from models.user_rbac_model import User
from schemas.physical_donation_schema import (
    MANILA,
    decode_pickup_days,
    pickup_area,
    pickup_rules,
)
from services.donation_expiry import entry_expiry_info, expire_overdue
from services.pickup_planner import PRIORITY_LEVELS, Donation, plan, planner_config
from api.v1.donation_routes import (
    PICKUP_ROLES,
    _distance_view,
    _donor_info,
    _iso,
    _num,
    _report_label,
)

router = APIRouter(prefix="/donations", tags=["Door to Door pickup plan"])


def _today() -> date:
    return datetime.now(MANILA).date()


def _ph_naive(at: Optional[datetime]) -> Optional[datetime]:
    """Stored UTC time -> Philippine wall time without tzinfo (SQLite gives
    naive UTC, Postgres gives aware)."""
    if at is None:
        return None
    if at.tzinfo is None:
        at = at.replace(tzinfo=timezone.utc)
    return at.astimezone(MANILA).replace(tzinfo=None)


def _priority(report: Optional[DisasterReport]) -> float:
    if report is None:
        return 0.0
    if report.ai_priority_score is not None:
        return float(report.ai_priority_score)
    return float(PRIORITY_LEVELS.get((report.priority_level or "").strip().lower(), 0))


def _waiting(db: Session) -> list:
    """Every Door to Door donation with items still Pending, as planner input."""
    refs = [
        r[0]
        for r in db.query(PhysicalDonation.batch_reference)
        .filter(PhysicalDonation.handover_method == "Door to Door",
                PhysicalDonation.status == "Pending")
        .distinct()
        .all()
    ]
    if not refs:
        return []
    rows = (
        db.query(PhysicalDonation)
        .filter(PhysicalDonation.batch_reference.in_(refs))
        .order_by(PhysicalDonation.donation_id)
        .all()
    )
    by_ref: dict = {}
    for r in rows:
        by_ref.setdefault(r.batch_reference, []).append(r)
    items = {
        i.item_id: i
        for i in db.query(Item).filter(Item.item_id.in_({r.item_id for r in rows})).all()
    }
    reports = {
        r.report_id: r
        for r in db.query(DisasterReport)
        .filter(DisasterReport.report_id.in_({r.report_id for r in rows}))
        .all()
    }
    labels: dict = {}

    # Stops already in an open DRRMO pickup run keep that run's date.
    runs: dict = {}
    for req in (db.query(LogisticsRequest)
                .filter(LogisticsRequest.request_type == "Pickup",
                        LogisticsRequest.status.in_(("Pending", "Accepted"))).all()):
        for ref in req.batch_list:
            runs[ref] = req

    out = []
    for ref, lines in by_ref.items():
        first = lines[0]
        pending = [l for l in lines if l.status == "Pending"]
        if first.report_id not in labels:
            labels[first.report_id] = _report_label(db, first.report_id)
        days = decode_pickup_days(first.pickup_days)
        if not days and first.preferred_pickup_at is not None:
            days = [first.preferred_pickup_at.astimezone(MANILA).isoweekday()]
        req = runs.get(ref)
        expiry = entry_expiry_info(lines)
        distance = _distance_view(first)
        out.append(Donation(
            ref=ref,
            lat=_num(first.pickup_lat),
            lng=_num(first.pickup_lng),
            days=days,
            # Only what is still waiting goes in the vehicle.
            items=[
                {
                    "item_name": items[l.item_id].item_name if l.item_id in items else "Item",
                    "unit": items[l.item_id].unit_of_measure if l.item_id in items else "",
                    "category": items[l.item_id].category if l.item_id in items else "",
                    "packaging": l.packaging,
                    "quantity": l.quantity,
                }
                for l in pending
            ],
            created_at=_ph_naive(first.created_at),
            not_home_date=max((l.pickup_not_home_date for l in pending if l.pickup_not_home_date),
                              default=None),
            run_date=req.pickup_date if req is not None else None,
            too_far=distance["too_far"],
            priority=_priority(reports.get(first.report_id)),
            days_left=expiry["days_left"],
            view={
                "pickup_address": first.pickup_address,
                "pickup_landmark": first.pickup_landmark,
                "pickup_notes": first.pickup_notes,
                "report_id": first.report_id,
                "report_label": labels[first.report_id],
                "created_at": _iso(first.created_at),
                "expires_label": expiry["expires_label"],
                "total_items": len(lines),
                "pending_items": len(pending),
                "pickup_request": None if req is None else {
                    "request_id": req.request_id,
                    "status": req.status,
                    "pickup_date": req.pickup_date.isoformat() if req.pickup_date else None,
                },
                **distance,
                **_donor_info(db, first),
            },
        ))
    return out


@router.get("/pickup-plan")
def pickup_plan(
    vehicle: Optional[str] = Query(None, max_length=40),
    db: Session = Depends(get_db),
    current_user: User = Depends(require_role(*PICKUP_ROLES)),
):
    expire_overdue(db)  # overdue pickups leave the plan
    rules = pickup_rules()
    cfg = planner_config()
    if vehicle and vehicle not in {v["key"] for v in cfg["vehicles"]}:
        raise HTTPException(status_code=422, detail=f"Unknown vehicle '{vehicle}'")
    result = plan(
        _waiting(db),
        today=_today(),
        office=tuple(pickup_area()["office"]),
        pickup_days=rules["days"],
        start_hour=rules["start_hour"],
        end_hour=rules["end_hour"],
        vehicle_key=vehicle,
        cfg=cfg,
    )
    area = pickup_area()
    result["office"] = {"lat": area["office"][0], "lng": area["office"][1]}
    result["max_km"] = area["max_km"]
    return result


class NotHomeRequest(BaseModel):
    # Every QR reference at the stop the picker visited.
    batch_references: List[str] = Field(min_length=1, max_length=50)
    # The day of the visit; defaults to today (Philippine time).
    visited_on: Optional[date] = None


@router.post("/pickup-plan/not-home")
def mark_not_home(
    payload: NotHomeRequest,
    db: Session = Depends(get_db),
    current_user: User = Depends(require_role(*PICKUP_ROLES)),
):
    day = payload.visited_on or _today()
    refs = sorted({r.strip().upper() for r in payload.batch_references if r.strip()})
    rows = (
        db.query(PhysicalDonation)
        .filter(PhysicalDonation.batch_reference.in_(refs),
                PhysicalDonation.handover_method == "Door to Door",
                PhysicalDonation.status == "Pending")
        .all()
    )
    found = {r.batch_reference for r in rows}
    missing = [r for r in refs if r not in found]
    if missing:
        raise HTTPException(
            status_code=404,
            detail=f"No Door to Door pickup still waiting for {', '.join(missing)}",
        )
    by_ref: dict = {}
    for r in rows:
        if r.pickup_not_home_date is None or r.pickup_not_home_date < day:
            r.pickup_not_home_date = day
        by_ref.setdefault(r.batch_reference, []).append(r)

    label = day.strftime("%a, %b ") + str(day.day)
    for ref, lines in by_ref.items():
        first = lines[0]
        log_action(db, current_user, "PICKUP NOT HOME", "physical_donations", first.donation_id,
                   new={"batch_reference": ref, "date": day.isoformat()})
        if first.user_id:
            notify(
                db, first.user_id, "pickup_not_home",
                "We missed you",
                f"CSWS came for donation {ref} on {label}, but nobody was home. "
                "We will come on your next pickup day. You can change your "
                "days in My giving.",
                "donation", first.donation_id,
            )
    db.commit()
    return {"batch_references": sorted(by_ref), "not_home_date": day.isoformat()}