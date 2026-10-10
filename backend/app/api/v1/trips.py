"""Delivery trips: several reports on one truck (team decision Oct 9, 2026).

Real case: 3 Banilad reports and 2 reports in nearby barangays go out in
one run. A trip groups ordinary deliveries; each delivery still has ONE
report and ONE barangay, so these keep working unchanged:
  - stock per report (Table 34), taken all-or-nothing for the whole trip
  - each barangay confirms its own receipt (UC-B1, alt 3a)
  - fulfillment per report (delivery module step 5)
  - the per-delivery status history (UC-CM2 / delivery module step 3)

Flow, in the words the app uses:
  1. Prepare trip     pick reports (suggested: same barangay first, then the
                      most urgent), items and quantities per report
  2. Start trip       every delivery in it goes "In Transit" with one tap
  3. Arrived at stop  every delivery for that barangay becomes "Delivered"
  4. Barangay rep     confirms receipt (one tap for all of their deliveries)
  5. Completed        automatically, when every delivery is confirmed
  Undo trip           only while still being prepared: stock goes back

No route optimisation: stops are in the order staff chose (Limitation 6).
"""
from datetime import date, datetime, timezone
from typing import List, Optional

from fastapi import APIRouter, Depends, HTTPException, Query, status
from pydantic import BaseModel, Field
from sqlalchemy.orm import Session, joinedload

from api.v1.deliveries import confirm_receipt, move_to_next_status
from core.audit import log_action
from core.auth import barangay_scope, require_role
from core.database import get_db
from models.barangay_model import Barangay
from models.delivery import Delivery, DeliveryItem, DeliveryTrip
from models.item_model import Item
from models.logistics_request_model import LogisticsRequest
from models.report import DisasterReport
from schemas.delivery import ReceiptConfirm
from schemas.physical_donation_schema import MANILA
from services.delivery_stock import check_stock, report_stock, take_stock
from services.delivery_views import delivery_views, report_labels

router = APIRouter(prefix="/trips", tags=["Delivery trips"])

CSWS = ("csws_main_office", "admin")
READERS = ("csws_main_office", "admin", "drrmo logistics support")
PRIORITY_RANK = {"Critical": 0, "High": 1, "Medium": 2, "Low": 3}

STATUS_LABELS = {
    "Preparing": "Being prepared",
    "In Transit": "On the road",
    "Delivered": "Delivered, waiting for barangay confirmation",
    "Completed": "Completed",
}


# ---------------------------------------------------------------------------
# Request bodies
# ---------------------------------------------------------------------------
class TripLine(BaseModel):
    item_id: int
    quantity: int = Field(gt=0)


class TripStop(BaseModel):
    report_id: int
    # Usually the report's own barangay, so the app may leave it out.
    destination_barangay_id: Optional[int] = None
    destination_sitio_id: Optional[int] = None
    items: List[TripLine] = Field(min_length=1)


class TripCreate(BaseModel):
    trip_date: datetime
    vehicle_details: Optional[str] = Field(default=None, max_length=300)
    notes: Optional[str] = Field(default=None, max_length=1000)
    reports: List[TripStop] = Field(min_length=1)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
def trip_status(statuses) -> str:
    """Worked out from the deliveries' statuses, so it can never disagree
    with them."""
    s = set(statuses)
    if not s:
        return "Preparing"
    if s == {"Confirmed"}:
        return "Completed"
    if "In Transit" in s:
        return "In Transit"
    if s == {"Preparing"}:
        return "Preparing"
    if s <= {"Delivered", "Confirmed"}:
        return "Delivered"
    return "In Transit"   # some left, some still at the office


def _trip_view(db: Session, trip: DeliveryTrip) -> dict:
    deliveries = sorted(trip.deliveries, key=lambda d: (d.stop_order or 0, d.delivery_id))
    views = delivery_views(db, deliveries)
    stops: dict = {}
    for v in views:
        stop = stops.setdefault(v["destination_barangay_id"], {
            "stop_order": v["stop_order"],
            "barangay_id": v["destination_barangay_id"],
            "barangay_name": v["destination_barangay_name"],
            "deliveries": [],
        })
        stop["deliveries"].append(v)
    for stop in stops.values():
        st = {d["status"] for d in stop["deliveries"]}
        stop["status"] = trip_status(st)
        stop["can_mark_arrived"] = "In Transit" in st
    code = trip_status(d.status for d in deliveries)
    return {
        "trip_id": trip.trip_id,
        "title": f"Trip #{trip.trip_id}",
        "trip_date": trip.trip_date,
        "vehicle_details": trip.vehicle_details,
        "notes": trip.notes,
        "handled_by_user_id": trip.handled_by_user_id,
        "created_at": trip.created_at,
        "status": code,
        "status_label": STATUS_LABELS[code],
        "total_reports": len({d.report_id for d in deliveries}),
        "total_stops": len(stops),
        "total_quantity": sum(i.quantity for d in deliveries for i in d.items),
        "delivery_counts": {s: sum(1 for d in deliveries if d.status == s)
                            for s in ("Preparing", "In Transit", "Delivered", "Confirmed")},
        "can_start": code == "Preparing",
        "can_undo": all(d.status == "Preparing" for d in deliveries),
        "stops": sorted(stops.values(), key=lambda s: s["stop_order"] or 0),
    }


def _get_trip(db: Session, trip_id: int) -> DeliveryTrip:
    trip = (
        db.query(DeliveryTrip)
        .options(joinedload(DeliveryTrip.deliveries).joinedload(Delivery.items))
        .filter(DeliveryTrip.trip_id == trip_id)
        .first()
    )
    if trip is None:
        raise HTTPException(status_code=404, detail="Trip not found")
    return trip


# ---------------------------------------------------------------------------
# Step 1 helper: which reports have goods ready to send
# ---------------------------------------------------------------------------
@router.get("/candidates")
def trip_candidates(
    near_barangay_id: Optional[int] = Query(default=None, description="Show this barangay's reports first"),
    q: Optional[str] = Query(default=None, max_length=100),
    db: Session = Depends(get_db),
    current_user=Depends(require_role(*CSWS)),
):
    """Validated reports that still have stock, grouped by barangay.
    Order: the chosen barangay first, then barangays with the most urgent
    report (priority, then the lowest fulfillment). Reports with no stock are
    listed separately so the screen can say "No more stock for this report"."""
    reports = db.query(DisasterReport).filter(DisasterReport.status == "Validated").all()
    labels = report_labels(db, [r.report_id for r in reports])
    brgys = {b.barangay_id: b.barangay_name for b in db.query(Barangay).all()}
    items = {i.item_id: i for i in db.query(Item).all()}

    ready, empty = [], []
    for r in reports:
        stock = report_stock(db, r.report_id)
        f = r.fulfillment
        row = {
            "report_id": r.report_id,
            "report_label": labels.get(r.report_id),
            "barangay_id": r.barangay_id,
            "barangay_name": brgys.get(r.barangay_id, "Barangay"),
            "sitio_id": r.sitio_id,
            "priority_level": r.priority_level,
            "fulfillment_percentage": float(f.fulfillment_percentage) if f else 0.0,
            "items": [
                {"item_id": iid, "item_name": items[iid].item_name if iid in items else f"Item #{iid}",
                 "unit": items[iid].unit_of_measure if iid in items else "", "quantity": qty}
                for iid, qty in sorted(stock.items(), key=lambda kv: items[kv[0]].item_name if kv[0] in items else "")
            ],
        }
        if q and q.strip():
            text = q.strip().lower().lstrip("#")
            if text not in (row["report_label"] or "").lower() and text not in row["barangay_name"].lower():
                continue
        (ready if stock else empty).append(row)

    def urgency(r):
        return (PRIORITY_RANK.get(r["priority_level"], 9), r["fulfillment_percentage"], r["report_id"])

    groups: dict = {}
    for r in ready:
        groups.setdefault(r["barangay_id"], {
            "barangay_id": r["barangay_id"], "barangay_name": r["barangay_name"], "reports": []
        })["reports"].append(r)
    for g in groups.values():
        g["reports"].sort(key=urgency)
    ordered = sorted(
        groups.values(),
        key=lambda g: (g["barangay_id"] != near_barangay_id, urgency(g["reports"][0]), g["barangay_name"]),
    )
    return {
        "barangays": ordered,
        "no_stock_reports": [
            {"report_id": r["report_id"], "report_label": r["report_label"],
             "barangay_name": r["barangay_name"], "message": "No more stock for this report"}
            for r in sorted(empty, key=urgency)
        ],
    }


# ---------------------------------------------------------------------------
# Step 1: prepare the trip
# ---------------------------------------------------------------------------
@router.post("/", status_code=status.HTTP_201_CREATED)
def create_trip(
    payload: TripCreate,
    db: Session = Depends(get_db),
    current_user=Depends(require_role(*CSWS)),
):
    """One delivery per report, all on one trip. Every report's stock is
    checked before anything is taken, so a shortage in one report leaves
    every report's inventory untouched."""
    seen = set()
    for stop in payload.reports:
        if stop.report_id in seen:
            raise HTTPException(
                status_code=400,
                detail=f"Report #{stop.report_id} is listed twice. Put all of its items under one report.",
            )
        seen.add(stop.report_id)

    reports = {}
    labels = report_labels(db, seen)
    for stop in payload.reports:
        report = db.get(DisasterReport, stop.report_id)
        if report is None:
            raise HTTPException(status_code=404, detail=f"Report #{stop.report_id} not found")
        if report.status != "Validated":
            raise HTTPException(status_code=409, detail=f"Report #{stop.report_id} is not validated, so it cannot receive deliveries.")
        if stop.destination_barangay_id and db.get(Barangay, stop.destination_barangay_id) is None:
            raise HTTPException(status_code=404, detail=f"Barangay #{stop.destination_barangay_id} not found")
        reports[stop.report_id] = report

    checked = [
        check_stock(db, stop.report_id, stop.items, report_name=f"report {labels.get(stop.report_id, stop.report_id)}")
        for stop in payload.reports
    ]
    for c in checked:
        take_stock(c)

    trip = DeliveryTrip(
        trip_date=payload.trip_date,
        vehicle_details=(payload.vehicle_details or "").strip() or None,
        notes=(payload.notes or "").strip() or None,
        handled_by_user_id=current_user.user_id,
    )
    db.add(trip)
    db.flush()

    stop_of: dict = {}   # barangay -> stop number, in the order staff listed them
    for stop in payload.reports:
        brgy = stop.destination_barangay_id or reports[stop.report_id].barangay_id
        stop_of.setdefault(brgy, len(stop_of) + 1)
        delivery = Delivery(
            report_id=stop.report_id,
            destination_barangay_id=brgy,
            destination_sitio_id=stop.destination_sitio_id,
            handled_by_user_id=current_user.user_id,
            status="Preparing",
            delivery_date=payload.trip_date,
            trip_id=trip.trip_id,
            stop_order=stop_of[brgy],
        )
        db.add(delivery)
        db.flush()
        for line in stop.items:
            db.add(DeliveryItem(delivery_id=delivery.delivery_id, item_id=line.item_id, quantity=line.quantity))
        # Same history entry a single delivery gets, plus the trip number.
        log_action(db, current_user, "PREPARE DELIVERY", "deliveries", delivery.delivery_id,
                   new={"status": "Preparing", "trip_id": trip.trip_id,
                        "items": [l.model_dump() for l in stop.items]})
    log_action(db, current_user, "PREPARE TRIP", "delivery_trips", trip.trip_id,
               new={"reports": [s.report_id for s in payload.reports], "stops": len(stop_of)})
    db.commit()
    return _trip_view(db, _get_trip(db, trip.trip_id))


# ---------------------------------------------------------------------------
# Reading trips
# ---------------------------------------------------------------------------
TRIP_SORTS = ("newest", "oldest", "date_soonest", "date_latest")


@router.get("/")
def list_trips(
    status_filter: Optional[str] = Query(default=None, alias="status",
                                         description="Preparing, In Transit, Delivered, Completed (comma-separated)"),
    date_from: Optional[date] = None,
    date_to: Optional[date] = None,
    barangay_id: Optional[int] = None,
    q: Optional[str] = Query(default=None, max_length=100),
    sort: str = Query(default="newest", pattern="^(" + "|".join(TRIP_SORTS) + ")$"),
    db: Session = Depends(get_db),
    current_user=Depends(require_role(*READERS)),
):
    trips = (
        db.query(DeliveryTrip)
        .options(joinedload(DeliveryTrip.deliveries).joinedload(Delivery.items))
        .all()
    )
    views = [_trip_view(db, t) for t in trips]
    if status_filter:
        wanted = {s.strip() for s in status_filter.split(",") if s.strip()}
        views = [v for v in views if v["status"] in wanted]
    if date_from or date_to:
        def local_day(v):
            d = v["trip_date"]
            return (d if d.tzinfo else d.replace(tzinfo=timezone.utc)).astimezone(MANILA).date()
        views = [v for v in views
                 if (not date_from or local_day(v) >= date_from) and (not date_to or local_day(v) <= date_to)]
    if barangay_id:
        views = [v for v in views if any(s["barangay_id"] == barangay_id for s in v["stops"])]
    if q and q.strip():
        text = q.strip().lower().lstrip("#").replace("trip", "").strip()
        views = [
            v for v in views
            if text == str(v["trip_id"])
            or any(text in (s["barangay_name"] or "").lower() for s in v["stops"])
            or text in (v["vehicle_details"] or "").lower()
        ]
    key = {
        "oldest": lambda v: (v["created_at"], v["trip_id"]),
        "date_soonest": lambda v: (v["trip_date"], v["trip_id"]),
        "date_latest": lambda v: (v["trip_date"], v["trip_id"]),
    }.get(sort, lambda v: (v["created_at"], v["trip_id"]))
    return sorted(views, key=key, reverse=sort in ("newest", "date_latest"))


@router.get("/{trip_id}")
def get_trip(
    trip_id: int,
    db: Session = Depends(get_db),
    current_user=Depends(require_role(*READERS)),
):
    return _trip_view(db, _get_trip(db, trip_id))


# ---------------------------------------------------------------------------
# Steps 2-4: start, arrive at each stop, barangay confirms
# ---------------------------------------------------------------------------
@router.post("/{trip_id}/start")
def start_trip(
    trip_id: int,
    db: Session = Depends(get_db),
    current_user=Depends(require_role(*CSWS)),
):
    """The truck leaves: every delivery still being prepared goes In Transit
    (same history and notifications as advancing one delivery)."""
    trip = _get_trip(db, trip_id)
    waiting = [d for d in trip.deliveries if d.status == "Preparing"]
    if not waiting:
        raise HTTPException(status_code=409, detail="This trip has already left.")
    for d in waiting:
        move_to_next_status(db, d, current_user)
    log_action(db, current_user, "START TRIP", "delivery_trips", trip.trip_id,
               new={"deliveries": [d.delivery_id for d in waiting]})
    db.commit()
    return _trip_view(db, _get_trip(db, trip_id))


@router.post("/{trip_id}/stops/{barangay_id}/arrived")
def arrived_at_stop(
    trip_id: int,
    barangay_id: int,
    db: Session = Depends(get_db),
    current_user=Depends(require_role(*CSWS)),
):
    """The truck reached this barangay: its deliveries become Delivered, and
    the barangay rep is notified to confirm receipt."""
    trip = _get_trip(db, trip_id)
    here = [d for d in trip.deliveries if d.destination_barangay_id == barangay_id]
    if not here:
        raise HTTPException(status_code=404, detail="This trip has no stop at that barangay.")
    moving = [d for d in here if d.status == "In Transit"]
    if not moving:
        if all(d.status == "Preparing" for d in here):
            raise HTTPException(status_code=409, detail="Start the trip first.")
        raise HTTPException(status_code=409, detail="This stop is already marked as arrived.")
    for d in moving:
        move_to_next_status(db, d, current_user)
    db.commit()
    return _trip_view(db, _get_trip(db, trip_id))


@router.post("/{trip_id}/confirm-receipt")
def confirm_trip_receipt(
    trip_id: int,
    payload: ReceiptConfirm,
    db: Session = Depends(get_db),
    current_user=Depends(require_role("barangay_receiving_rep", "admin")),
):
    """Barangay rep: confirm every delivery from this trip that arrived in
    their barangay at once (e.g. 3 Banilad reports = 3 deliveries, one tap).
    Each one is still confirmed through the normal receipt rules (UC-B1),
    so fulfillment updates per report."""
    trip = _get_trip(db, trip_id)
    own = barangay_scope(current_user)
    mine = [d for d in trip.deliveries if own is None or d.destination_barangay_id == own]
    if not mine:
        raise HTTPException(status_code=404, detail="This trip has no deliveries for your barangay.")
    ready = [d.delivery_id for d in mine if d.status == "Delivered"]
    if not ready:
        raise HTTPException(status_code=409, detail="Nothing to confirm yet: the goods have not arrived.")
    for delivery_id in ready:
        confirm_receipt(delivery_id, payload, db=db, current_user=current_user)
    db.commit()
    return {"trip_id": trip_id, "confirmed_deliveries": ready}


# ---------------------------------------------------------------------------
# Undo while still at the office
# ---------------------------------------------------------------------------
@router.delete("/{trip_id}")
def undo_trip(
    trip_id: int,
    db: Session = Depends(get_db),
    current_user=Depends(require_role(*CSWS)),
):
    """Made a mistake while preparing? Undo the whole trip: its deliveries
    are removed and every item goes back to its report's stock. Only while
    nothing has left the office. The history keeps a record of the undo."""
    trip = _get_trip(db, trip_id)
    if any(d.status != "Preparing" for d in trip.deliveries):
        raise HTTPException(status_code=409, detail="This trip has already left, so it can no longer be undone.")
    ids = [d.delivery_id for d in trip.deliveries]
    if ids and db.query(LogisticsRequest).filter(LogisticsRequest.delivery_id.in_(ids)).first():
        raise HTTPException(
            status_code=409,
            detail="A DRRMO transport request is linked to this trip. Ask DRRMO to decline it first.",
        )
    from models.inventory_model import Inventory
    returned = []
    for d in trip.deliveries:
        for line in d.items:
            inv = (db.query(Inventory)
                   .filter(Inventory.item_id == line.item_id, Inventory.report_id == d.report_id).first())
            inv.quantity += line.quantity
            returned.append({"report_id": d.report_id, "item_id": line.item_id, "quantity": line.quantity})
        log_action(db, current_user, "UNDO DELIVERY", "deliveries", d.delivery_id,
                   old={"status": "Preparing", "trip_id": trip_id}, new={"removed": True})
        db.delete(d)
    log_action(db, current_user, "UNDO TRIP", "delivery_trips", trip_id,
               old={"deliveries": ids}, new={"returned_to_stock": returned})
    db.delete(trip)
    db.commit()
    return {"trip_id": trip_id, "undone": True, "returned_to_stock": returned}
