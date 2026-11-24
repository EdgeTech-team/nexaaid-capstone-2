"""Door to Door pickup plan for CSWS Main Office (Oct 12 notes, pickup
logic v2; manuscript UC-D2 alt 7c and UC-CM1 for Door to Door).

GET  /donations/pickup-plan
     Waiting Door to Door donations grouped into stops (same landmark AND a
     shared day), planned on a date in the next two weeks by plain urgency
     rules (no scoring), in a one-way order from the CSWS office. Decision support
     only: CSWS confirms the run (manuscript: the system suggests, staff
     decide). Donations without a usable pin come back in "follow_up".

POST /donations/pickup-plan/not-home
     The picker found nobody home. The stop moves to the donor's next
     allowed day after that date. The donor (if registered) is told.

POST /donations/entries/{ref}/contact-check        (NF-007, D5)
     Staff called the donor to confirm the stop: Reached / No answer /
     Wrong number. A pickup run cannot be sent while one of its stops has
     no Reached call (409 listing them, POST /logistics/pickup-requests).
     Wrong number cancels the entry ("Contact number not reachable"); a
     second No answer in a row moves the stop to the donor's next date.
     CSWS Main Office, DRRMO and the Administrator.

"Mark picked up" is the existing receiving flow (scan the QR / open the
entry): the picker's count is saved in received_goods.actual_quantity,
separate from what the donor declared (manuscript limitation 3).

Same roles as GET /donations/pickups: CSWS Main Office and Administrator.
Donors, DRRMO and the Disaster Unit get 403.
"""
from datetime import date, datetime, timezone
from typing import List, Literal, Optional

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field
from sqlalchemy.orm import Session

from core.shared.audit import log_action
from core.m1_user_management.auth import has_role, require_role
from core.shared.database import get_db
from core.notifications.notifications import notify
from core.reference_data.barangay_model import Barangay
from core.reference_data.item_model import Item
from core.m7_logistics_support.logistics_request_model import LogisticsRequest
from core.m4_donation_management.physical_donation_model import PhysicalDonation
from core.m1_user_management.user_rbac_model import User
from core.m4_donation_management.physical_donation_schema import (
    MANILA,
    decode_pickup_dates,
    decode_pickup_days,
    pickup_area,
    pickup_rules,
)
from core.m4_donation_management.donation_expiry import close_rows, entry_expiry_info, expire_overdue, now_utc
from core.m4_donation_management.email_hold import not_held
from core.reference_data.item_quantities import donated_item_fields
from core.m5_inventory.pickup_barangay import barangay_finder
from core.m5_inventory.pickup_planner import Donation, plan, planner_config
from core.m5_inventory.pickup_zones import ZONES, zone_of
from core.m4_donation_management.donation_routes import (
    PICKUP_ROLES,
    _batch_rows,
    _distance_view,
    _donor_info,
    _drop_from_pickup_runs,
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


def _waiting(db: Session) -> list:
    """Every Door to Door donation with items still Pending, as planner input."""
    refs = [
        r[0]
        for r in db.query(PhysicalDonation.batch_reference)
        .filter(PhysicalDonation.handover_method == "Door to Door",
                PhysicalDonation.status == "Pending",
                not_held())   # NF-006: waiting for the donor's email code
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
    labels: dict = {}
    # Barangay label for the pickup list (read from the address text).
    find_barangay = barangay_finder(n for (n,) in db.query(Barangay.barangay_name).all())

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
        # Oct 23 (approved by Daniel): pickup details come from the items
        # still waiting, so a removed first item never hides the pickup.
        spot = pending[0] if pending else first
        if first.report_id not in labels:
            labels[first.report_id] = _report_label(db, first.report_id)
        days = decode_pickup_days(spot.pickup_days)
        if not days and spot.preferred_pickup_at is not None:
            days = [spot.preferred_pickup_at.astimezone(MANILA).isoweekday()]
        req = runs.get(ref)
        expiry = entry_expiry_info(lines)
        distance = _distance_view(spot)
        # Fixed pickup zone (core/m5_inventory/pickup_zones.py, testing Oct 31).
        zone = zone_of(spot.pickup_address, spot.pickup_landmark,
                       _num(spot.pickup_lat), _num(spot.pickup_lng))
        out.append(Donation(
            ref=ref,
            zone=zone,
            lat=_num(spot.pickup_lat),
            lng=_num(spot.pickup_lng),
            days=days,
            dates=decode_pickup_dates(spot.pickup_dates),
            # Only what is still waiting is collected.
            items=[
                {
                    "item_name": items[l.item_id].item_name if l.item_id in items else "Item",
                    "unit": items[l.item_id].unit_of_measure if l.item_id in items else "",
                    "quantity": l.quantity,
                    # G-002 (D8): packaging, "10 packs x 5 kg", declared.
                    **donated_item_fields(
                        l, items[l.item_id].unit_of_measure if l.item_id in items else ""),
                }
                for l in pending
            ],
            created_at=_ph_naive(first.created_at),
            not_home_date=max((l.pickup_not_home_date for l in pending if l.pickup_not_home_date),
                              default=None),
            run_date=req.pickup_date if req is not None else None,
            too_far=distance["too_far"],
            days_left=expiry["days_left"],
            view={
                # The barangay list is Mandaue's: outside Mandaue a word like
                # "Poblacion" is another town's, so no label there.
                "barangay": (find_barangay(spot.pickup_address, spot.pickup_landmark)
                             if zone is None or zone.startswith("Mandaue") else None),
                "pickup_address": spot.pickup_address,
                "pickup_landmark": spot.pickup_landmark,
                "pickup_notes": spot.pickup_notes,
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
                # NF-007 (D5): the confirmation call for this stop.
                **contact_view(spot),
            },
        ))
    return out


def contact_view(row: PhysicalDonation) -> dict:
    return {
        "contact_outcome": row.contact_outcome,
        "contact_confirmed_at": _iso(row.contact_confirmed_at),
        "contact_confirmed": row.contact_outcome == "Reached",
    }


def clear_contact(rows) -> None:
    """A new date or place needs a new confirmation call."""
    for r in rows:
        r.contact_confirmed_at = None
        r.contact_confirmed_by_user_id = None
        r.contact_outcome = None


@router.get("/pickup-plan")
def pickup_plan(
    db: Session = Depends(get_db),
    current_user: User = Depends(require_role(*PICKUP_ROLES)),
):
    expire_overdue(db)  # overdue pickups leave the plan
    rules = pickup_rules()
    result = plan(
        _waiting(db),
        today=_today(),
        office=tuple(pickup_area()["office"]),
        pickup_days=rules["days"],
        start_hour=rules["start_hour"],
        end_hour=rules["end_hour"],
        cfg=planner_config(),
    )
    area = pickup_area()
    result["office"] = {"lat": area["office"][0], "lng": area["office"][1]}
    result["max_km"] = area["max_km"]
    # The fixed zones, for the legend and the zone colours (testing, Oct 31).
    result["zones"] = [{"name": z["name"], "code": z["code"], "city": z["city"]} for z in ZONES]
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
    clear_contact(rows)   # NF-007: the next date needs a new call

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
                "We will come on your next pickup date. You can change your "
                "dates in My giving.",
                "donation", first.donation_id,
            )
    db.commit()
    return {"batch_references": sorted(by_ref), "not_home_date": day.isoformat()}

# ---------------------------------------------------------------------------
# NF-007 (D5): call to confirm every pickup stop
# ---------------------------------------------------------------------------
CONTACT_ROLES = ("CSWS Main Office", "DRRMO Logistics Support", "Administrator")
CONTACT_OUTCOMES = ("Reached", "No answer", "Wrong number")
WRONG_NUMBER_REASON = "Contact number not reachable"


class ContactCheckRequest(BaseModel):
    outcome: Literal[CONTACT_OUTCOMES]
    # The date the stop was planned for. A second No answer moves the stop
    # after it. Defaults to today (Philippine time).
    planned_date: Optional[date] = None


@router.post("/entries/{reference}/contact-check")
def contact_check(
    reference: str,
    payload: ContactCheckRequest,
    db: Session = Depends(get_db),
    current_user: User = Depends(require_role(*CONTACT_ROLES)),
):
    """Record the call that confirms a Door to Door stop (Reached / No
    answer / Wrong number) on every item still waiting."""
    rows = _batch_rows(db, reference)
    pending = [r for r in rows if r.status == "Pending"]
    ref = rows[0].batch_reference
    if not pending or pending[0].handover_method != "Door to Door":
        raise HTTPException(status_code=409,
                            detail=f"{ref} has no Door to Door pickup still waiting.")
    before = pending[0].contact_outcome
    now = now_utc()
    for r in pending:
        r.contact_confirmed_at = now
        r.contact_confirmed_by_user_id = current_user.user_id
        r.contact_outcome = payload.outcome

    result = {"batch_reference": ref, "contact_outcome": payload.outcome,
              "contact_confirmed_at": _iso(now), "cancelled": False, "moved": False,
              "not_home_date": None}
    first = pending[0]
    if payload.outcome == "Wrong number":
        close_rows(pending, "Cancelled", WRONG_NUMBER_REASON, user_id=current_user.user_id)
        _drop_from_pickup_runs(db, ref)
        result["cancelled"] = True
        if first.user_id:
            notify(db, first.user_id, "pickup_contact_unreachable", "Pickup cancelled",
                   f"CSWS could not reach you at your contact number for donation {ref}, "
                   "so the pickup was cancelled. Update your contact number and donate "
                   "again, or bring it to the CSWS office.",
                   "donation", first.donation_id)
    elif payload.outcome == "No answer" and before == "No answer":
        # Second No answer in a row: the stop moves to the donor's next date.
        day = payload.planned_date or _today()
        for r in pending:
            if r.pickup_not_home_date is None or r.pickup_not_home_date < day:
                r.pickup_not_home_date = day
        clear_contact(pending)
        _drop_from_pickup_runs(db, ref)
        result.update(moved=True, contact_outcome=None, not_home_date=day.isoformat())
        if first.user_id:
            notify(db, first.user_id, "pickup_contact_no_answer", "We could not reach you",
                   f"CSWS called twice about the pickup of donation {ref} but nobody "
                   "answered. We will plan it on your next pickup date and call again.",
                   "donation", first.donation_id)
    log_action(db, current_user, "PICKUP CONTACT CHECK", "physical_donations", first.donation_id,
               old={"contact_outcome": before},
               new={"batch_reference": ref, "contact_outcome": payload.outcome,
                    "cancelled": result["cancelled"], "moved": result["moved"]})
    db.commit()
    return result
