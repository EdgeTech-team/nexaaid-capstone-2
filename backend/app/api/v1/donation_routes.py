"""Physical donations (manuscript UC-D2, Physical Donation module, UC-D3/D4,
UC-R3/R4) plus the CSWS lookup of one donation by its QR (UC-CM1 step 2).

One donation = one QR reference (batch_reference), however many items.
Every item is still its own physical_donations row, so receiving, CMO
confirmation, inventory and deliveries keep working per item.
"""
import base64
import io
import os
import time
import uuid
from datetime import datetime, timezone
from typing import Optional

import httpx
import qrcode
from services.items import resolve_item_id
from services.units import line_amounts, describe as describe_amount
from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy.orm import Session

from core.database import get_db
from core.auth import get_current_user, get_current_user_optional, has_role, require_role
from models.user_rbac_model import User
from models.guest_donor_model import GuestDonor
from models.physical_donation_model import PhysicalDonation
from models.received_goods_model import ReceivedGoods
from models.item_model import Item
from models.logistics_request_model import LogisticsRequest
from models.notification import Notification
from models.organization_model import Organization
from models.report import DisasterReport, DisasterType, Barangay
from models.delivery import Delivery
from services.delivery_allocation import add_delivery_progress
from schemas.physical_donation_schema import (
    DonationBatchCreate,
    DonationEntryEdit,
    DonationItemRemove,
    DonationItemsAdd,
    PhysicalDonationCreate,
    PhysicalDonationResponse,
    pickup_rules,
    pickup_rules_view,
    pickup_area,
    km_from_office,
    encode_pickup_days,
    decode_pickup_days,
    pickup_days_label,
    encode_pickup_dates,
    decode_pickup_dates,
    pickup_dates_label,
    in_service_area,
    place_in,
    service_areas_label,
)
from core.audit import log_action
from core.notifications import notify_event, notify_event_many, user_ids_with_role
from services.donation_entries import build_entries, filter_and_sort, group_by_report
from services.donation_additions import (
    REMOVED_PREFIX, change_blocked, is_removed, next_addition_no, next_item_number,
    removed_notes, removed_reason, summary as additions_summary, summary_text,
)
from services.donation_expiry import (
    close_rows, entry_expiry_info, entry_status, expire_overdue, set_deadline, now_utc,
)

router = APIRouter(prefix="/donations", tags=["Physical Donations"])

CSWS_ROLES = ("CSWS Main Office", "Administrator")
# The Door to Door pickup list and map: CSWS Main Office (Oct 11 notes: the
# Disaster Unit no longer has the pickup map).
PICKUP_ROLES = CSWS_ROLES

# Address search (UC-D2 alt 7c) uses OpenStreetMap data through Photon:
# free, no API key, no billing. GEOCODER_URL can point to a self-hosted
# Photon server later without any app change.
SEARCH_CENTER = (10.3300, 123.9300)             # (lat, lng) Mandaue City centre: results near here rank first
# minLon,minLat,maxLon,maxLat: the pickup area (all of Cebu province unless
# PICKUP_AREA_BBOX says otherwise), so landmark suggestions stay inside it.
SEARCH_BBOX = ",".join(str(x) for x in pickup_area()["bbox"])
_GEO_CACHE: dict = {}
_GEO_CACHE_TTL = 24 * 3600                      # seconds
_GEO_CACHE_MAX = 1000


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
def _new_reference() -> str:
    return f"DON-{uuid.uuid4().hex[:12].upper()}"


def _qr_b64(text: str) -> str:
    buffer = io.BytesIO()
    qrcode.make(text).save(buffer, format="PNG")
    return base64.b64encode(buffer.getvalue()).decode()


def _num(v) -> Optional[float]:
    return float(v) if v is not None else None


def _iso(v: Optional[datetime]) -> Optional[str]:
    """Datetime as ISO 8601 with a timezone (stored times are UTC)."""
    if v is None:
        return None
    if v.tzinfo is None:
        v = v.replace(tzinfo=timezone.utc)
    return v.isoformat()


def _get_report(db: Session, report_id: int, require_validated: bool) -> DisasterReport:
    report = db.get(DisasterReport, report_id)
    if report is None:
        # Physical Donation module alt 4a: linked report no longer exists.
        raise HTTPException(status_code=404, detail="The selected report no longer exists")
    if require_validated and report.status != "Validated":
        # UC-D2 alt 2a: only validated reports can be supported.
        raise HTTPException(status_code=400, detail="Only validated reports can receive donations")
    return report


def _donor_ids(db: Session, current_user: Optional[User], guest_info) -> tuple:
    """(user_id, guest_donor_id). Guests are allowed by UC-D2 preconditions."""
    if current_user is not None:
        # Appendix H 4.1/4.2: donors, relief organizations and guests give.
        # Staff accounts record and process donations, they do not make them.
        if not has_role(current_user, "Individual Donor", "Relief Organization"):
            raise HTTPException(
                status_code=403,
                detail="Staff accounts cannot submit donations. Log out to donate as a guest.",
            )
        return current_user.user_id, None
    if guest_info is None:
        raise HTTPException(
            status_code=400,
            detail="Log in, or provide guest_donor details to donate anonymously.",
        )
    guest = GuestDonor(
        full_name=guest_info.full_name,
        contact_number=guest_info.contact_number,
        email=guest_info.email,
    )
    db.add(guest)
    db.flush()  # assigns guest.guest_donor_id without committing yet
    return None, guest.guest_donor_id


def _resolve_item_id(db: Session, item_id, other_name, other_unit) -> int:
    # Moved to services/items.py (reports use it for their needs too).
    return resolve_item_id(db, item_id, other_name, other_unit)


def _report_label(db: Session, report_id: int) -> Optional[str]:
    r = db.get(DisasterReport, report_id)
    if r is None:
        return None
    t = db.get(DisasterType, r.disaster_type_id)
    b = db.get(Barangay, r.barangay_id)
    return f"#{r.report_id} {t.type_name if t else 'Disaster'} - {b.barangay_name if b else 'Barangay'}"


def _donor_info(db: Session, d: PhysicalDonation) -> dict:
    """Who donated and how to reach them. Staff-only (CSWS / Admin)."""
    if d.user_id:
        u = db.get(User, d.user_id)
        if u is None:
            return {"donor": "Donor", "donor_type": "Registered",
                    "donor_contact": None, "donor_email": None}
        org = db.get(Organization, u.organization_id) if u.organization_id else None
        name = f"{u.first_name} {u.last_name}".strip()
        return {
            "donor": f"{name} ({org.org_name})" if org else name,
            "donor_type": "Organization" if org else "Registered",
            "donor_contact": u.contact_number,
            "donor_email": u.email,
        }
    g = db.get(GuestDonor, d.guest_donor_id) if d.guest_donor_id else None
    return {
        "donor": f"{g.full_name} (guest)" if g else "Guest",
        "donor_type": "Guest",
        "donor_contact": g.contact_number if g else None,
        "donor_email": g.email if g else None,
    }


def _pickup_days_view(d: PhysicalDonation) -> dict:
    """Door to Door pickup days for the screens: [1, 3], "Mon, Wed" and
    the pickup hours they apply to ("9:00 AM to 5:00 PM"). With specific
    dates (calendar picker) the label lists the dates: "Mon, Oct 26 · Wed, Oct 28"."""
    dates = decode_pickup_dates(d.pickup_dates)
    return {
        "pickup_days": decode_pickup_days(d.pickup_days),
        "pickup_dates": [x.isoformat() for x in dates],
        "pickup_days_label": pickup_dates_label(d.pickup_dates) or pickup_days_label(d.pickup_days),
        "pickup_hours": pickup_rules()["hours_label"] if d.pickup_days or dates else None,
    }


def _distance_view(d: PhysicalDonation) -> dict:
    """How far the pickup is from the CSWS office, and whether that is
    farther than PICKUP_MAX_KM (Main Office may decline it)."""
    km = km_from_office(d.pickup_lat, d.pickup_lng)
    return {"distance_km": km, "too_far": km is not None and km > pickup_area()["max_km"]}


def _batch_status(statuses: set) -> str:
    # Shared with the entry screens; also knows Expired / Cancelled.
    return entry_status(statuses)


def _batch_rows(db: Session, reference: str) -> list:
    """All rows of the donation a reference belongs to. Accepts the batch
    reference (what the QR holds) or any per-item qr_reference."""
    ref = reference.strip().upper()
    hit = (
        db.query(PhysicalDonation)
        .filter((PhysicalDonation.batch_reference == ref) | (PhysicalDonation.qr_reference == ref))
        .first()
    )
    if hit is None:
        raise HTTPException(status_code=404, detail=f"No donation with reference {reference}")
    return (
        db.query(PhysicalDonation)
        .filter(PhysicalDonation.batch_reference == hit.batch_reference)
        .order_by(PhysicalDonation.donation_id)
        .all()
    )


def _pickup_row(rows: list) -> PhysicalDonation:
    """The row whose pickup details apply now: the first item still waiting
    to be collected, else the first item (Oct 23, approved by Daniel)."""
    return next((r for r in rows if r.status == "Pending"), rows[0])


def _history(db: Session, rows: list) -> list:
    """Who did what to this donation and when (audit_logs), newest first.
    Staff only (UC-A4 activity logs, scoped to one donation)."""
    from models.audit_log_model import AuditLog
    ids = [r.donation_id for r in rows]
    logs = (db.query(AuditLog)
            .filter(AuditLog.entity_type == "physical_donations", AuditLog.entity_id.in_(ids))
            .order_by(AuditLog.log_id.desc()).limit(50).all())
    users = {u.user_id: f"{u.first_name} {u.last_name}".strip() for u in db.query(User).filter(
        User.user_id.in_({l.user_id for l in logs if l.user_id})).all()} if logs else {}
    return [
        {
            "action": l.action,
            "by": users.get(l.user_id, "System") if l.user_id else "System",
            "at": _iso(l.timestamp),
            "details": l.new_value,
        }
        for l in logs
    ]


def _batches(view_items: list) -> list:
    """Items grouped by batch: 1 = original pledge, 2+ = added later."""
    out: dict = {}
    for i in view_items:
        b = out.setdefault(i["addition_no"], {
            "addition_no": i["addition_no"],
            "label": f"Batch {i['addition_no']}",
            "added_later": i["addition_no"] > 1,
            "added_at": i["added_at"],
            "items": [],
        })
        b["items"].append(i)
    return [out[k] for k in sorted(out)]


def _batch_view(db: Session, rows: list, staff: bool) -> dict:
    first = rows[0]
    pickup = _pickup_row(rows)
    item_ids = {r.item_id for r in rows}
    items = {i.item_id: i for i in db.query(Item).filter(Item.item_id.in_(item_ids)).all()}
    received = {
        g.donation_id: g.actual_quantity
        for g in db.query(ReceivedGoods)
        .filter(ReceivedGoods.donation_id.in_([r.donation_id for r in rows]))
        .all()
    }
    view = {
        "batch_reference": first.batch_reference,
        "qr_image_base64": _qr_b64(first.batch_reference),
        "status": _batch_status({r.status for r in rows}),
        "report_id": first.report_id,
        "report_label": _report_label(db, first.report_id),
        "handover_method": pickup.handover_method,
        "pickup_address": pickup.pickup_address,
        "pickup_lat": _num(pickup.pickup_lat),
        "pickup_lng": _num(pickup.pickup_lng),
        "pickup_landmark": pickup.pickup_landmark,
        "pickup_notes": pickup.pickup_notes,
        **_pickup_days_view(pickup),
        "preferred_pickup_at": _iso(pickup.preferred_pickup_at),
        "created_at": first.created_at,
        # Handover deadline / why it was closed (services/donation_expiry.py)
        **entry_expiry_info(rows),
        "total_items": len(rows),
        "items": [
            {
                "donation_id": r.donation_id,
                "qr_reference": r.qr_reference,
                "item_id": r.item_id,
                "item_name": items[r.item_id].item_name if r.item_id in items else "Item",
                "unit": items[r.item_id].unit_of_measure if r.item_id in items else "",
                "quantity": r.quantity,
                "packaging": r.packaging,
                # Per-item fulfillment: how the donor described it (NULL
                # for older donations) and a readable line for the screens.
                "pack_count": r.pack_count,
                "per_pack": r.per_pack,
                "size_amount": _num(r.size_amount),
                "size_label": r.size_label,
                "amount_text": describe_amount(r, items[r.item_id].unit_of_measure if r.item_id in items else ""),
                "estimated_value": _num(r.estimated_value),
                "status": r.status,
                "actual_quantity_received": received.get(r.donation_id),
                # Oct 23: the batch it came with, when, and if the donor
                # removed it, why (it stays listed, marked removed).
                "addition_no": r.addition_no or 1,
                "added_at": _iso(r.created_at),
                "added_later": (r.addition_no or 1) > 1,
                "removed_by_donor": is_removed(r),
                "removed_reason": removed_reason(r),
                "close_reason": r.close_reason,
            }
            for r in rows
        ],
    }
    counts = additions_summary(rows)
    view.update({
        "batches": _batches(view["items"]),
        "summary": counts,
        "summary_text": summary_text(counts),
        "removed_notes": [
            {**n, "removed_at": _iso(n["removed_at"]),
             "item_name": items[n["item_id"]].item_name if n["item_id"] in items else "Item"}
            for n in removed_notes(rows)
        ],
    })
    if staff:
        view.update(_donor_info(db, first))
        view["history"] = _history(db, rows)
    return view


# ---------------------------------------------------------------------------
# UC-D2 step 6: create a donation
# ---------------------------------------------------------------------------
@router.post("/batch", status_code=201)
def create_donation_batch(
    payload: DonationBatchCreate,
    db: Session = Depends(get_db),
    current_user: User | None = Depends(get_current_user_optional),
):
    """One donation with one or more items, one QR reference. All items are
    saved together or none are (alt 3a: no QR for an incomplete entry)."""
    _get_report(db, payload.report_id, require_validated=True)
    _check_service_area(payload)
    user_id, guest_donor_id = _donor_ids(db, current_user, payload.guest_donor)

    batch_reference = _new_reference()
    rows = []
    for n, line in enumerate(payload.items, start=1):
        item_id = _resolve_item_id(db, line.item_id, line.other_item_name, line.other_item_unit)
        row = PhysicalDonation(
            user_id=user_id,
            guest_donor_id=guest_donor_id,
            report_id=payload.report_id,
            item_id=item_id,
            # quantity (base unit) + packaging + breakdown (services/units.py)
            **line_amounts(db, db.get(Item, item_id), line),
            estimated_value=line.estimated_value,
            handover_method=payload.handover_method,
            pickup_address=payload.pickup_address,
            pickup_lat=payload.pickup_lat,
            pickup_lng=payload.pickup_lng,
            pickup_landmark=payload.pickup_landmark,
            pickup_notes=payload.pickup_notes,
            pickup_days=encode_pickup_days(payload.pickup_days),
            pickup_dates=encode_pickup_dates(payload.pickup_dates),
            preferred_pickup_at=payload.preferred_pickup_at,
            qr_reference=f"{batch_reference}-{n}",
            batch_reference=batch_reference,
            status="Pending",
        )
        db.add(row)
        rows.append(row)
    set_deadline(rows)  # handover deadline (services/donation_expiry.py)
    db.flush()  # assigns donation_id for the notifications

    if current_user:  # guest donors have no account
        notify_event(db, current_user.user_id, "donation_submitted_confirm",
                     "donation", rows[0].donation_id, batch_no=batch_reference)
    # Linked to the donation so CSWS can open it from the notification.
    notify_event_many(db, user_ids_with_role(db, ["CSWS Main Office"]),
                      "donation_submitted", "donation", rows[0].donation_id,
                      batch_no=batch_reference)

    db.commit()
    for row in rows:
        db.refresh(row)
    return _batch_view(db, rows, staff=False)


@router.post("/", response_model=PhysicalDonationResponse)
def create_donation(
    payload: PhysicalDonationCreate,
    db: Session = Depends(get_db),
    current_user: User | None = Depends(get_current_user_optional),
):
    """Single-item donation, kept for older clients. Same as a batch of one."""
    _get_report(db, payload.report_id, require_validated=False)
    _check_service_area(payload)
    user_id, guest_donor_id = _donor_ids(db, current_user, payload.guest_donor)
    reference = _new_reference()

    item_id = _resolve_item_id(db, payload.item_id, payload.other_item_name, payload.other_item_unit)
    donation = PhysicalDonation(
        user_id=user_id,
        guest_donor_id=guest_donor_id,
        report_id=payload.report_id,
        item_id=item_id,
        **line_amounts(db, db.get(Item, item_id), payload),
        estimated_value=payload.estimated_value,
        handover_method=payload.handover_method,
        pickup_address=payload.pickup_address,
        pickup_lat=payload.pickup_lat,
        pickup_lng=payload.pickup_lng,
        pickup_landmark=payload.pickup_landmark,
        pickup_notes=payload.pickup_notes,
        pickup_days=encode_pickup_days(payload.pickup_days),
        pickup_dates=encode_pickup_dates(payload.pickup_dates),
        preferred_pickup_at=payload.preferred_pickup_at,
        qr_reference=reference,
        batch_reference=reference,
        status="Pending",
    )
    db.add(donation)
    set_deadline([donation])  # handover deadline (services/donation_expiry.py)
    db.flush()  # assigns donation_id for the notifications

    if current_user:  # guest donors have no account
        notify_event(db, current_user.user_id, "donation_submitted_confirm",
                     "donation", donation.donation_id, batch_no=donation.donation_id)
    notify_event_many(db, user_ids_with_role(db, ["CSWS Main Office"]),
                      "donation_submitted", "donation", donation.donation_id, batch_no=donation.qr_reference)

    db.commit()
    db.refresh(donation)
    return donation


# ---------------------------------------------------------------------------
# Oct 11 notes: the donor edits or deletes their own donation while nothing
# of it was received yet. Staff screens update by themselves (the entry
# changes or disappears from their lists); no notifications are sent.
# ---------------------------------------------------------------------------
_DONOR_EDITABLE = {"Pending", "Cancelled"}   # a declined donation can be fixed
_DONOR_DELETABLE = {"Pending", "Cancelled", "Expired"}


def _own_entry(db: Session, reference: str, user: User, allowed: set, action: str) -> list:
    rows = _batch_rows(db, reference)
    if rows[0].user_id != user.user_id:
        raise HTTPException(status_code=403, detail=f"You can only {action} your own donations.")
    if any(r.status not in allowed for r in rows):
        raise HTTPException(
            status_code=409,
            detail=f"CSWS already received part of this donation, so it can no longer be {action}d.",
        )
    return rows


def _drop_from_pickup_runs(db: Session, reference: str) -> None:
    """Take the entry out of open DRRMO pickup runs. A run left with no stop
    is cancelled; nothing else changes for DRRMO."""
    for req in (db.query(LogisticsRequest)
                .filter(LogisticsRequest.request_type == "Pickup",
                        LogisticsRequest.status.in_(("Pending", "Accepted"))).all()):
        refs = req.batch_list
        if reference not in refs:
            continue
        refs = [r for r in refs if r != reference]
        req.pickup_batches = ",".join(refs) or None
        if not refs:
            req.status = "Cancelled"
            note = "Cancelled: the donor changed or removed the only stop."
            req.notes = f"{req.notes}\n{note}" if req.notes else note
            req.pickup_batches = reference  # keep the history readable


# ---------------------------------------------------------------------------
# Oct 23 (Dave): add items to a pledged donation, or remove one, keeping the
# SAME donation and QR. Rules: services/donation_additions.py. Both are the
# donor's own actions; CSWS Main Office is notified so it sees the change
# before scanning, and the audit log keeps who did it and when.
# ---------------------------------------------------------------------------
def _own_rows(db: Session, reference: str, user: User, action: str) -> list:
    rows = _batch_rows(db, reference)
    if rows[0].user_id is None or rows[0].user_id != user.user_id:
        raise HTTPException(status_code=403, detail=f"You can only {action} your own donations.")
    blocked = change_blocked(db.get(DisasterReport, rows[0].report_id), rows)
    if blocked:
        raise HTTPException(status_code=409, detail=blocked)
    return rows


@router.post("/entries/{reference}/items", status_code=201)
def add_items_to_entry(
    reference: str,
    payload: DonationItemsAdd,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    """More items for the same donation: a new batch (Batch 2, 3 ...) with
    the same QR, handover and pickup. The new items start Pending; items
    already pledged keep their status and dates."""
    rows = _own_rows(db, reference, current_user, "add items to")
    first, base = rows[0], _pickup_row(rows)
    ref = first.batch_reference
    number, k = next_addition_no(rows), next_item_number(rows)
    # The new items join the same handover, so they share its deadline.
    from services.donation_expiry import effective_deadline
    deadlines = [effective_deadline(r) for r in rows if r.status == "Pending"]
    deadline = max((d for d in deadlines if d), default=None)
    new = []
    for line in payload.items:
        item_id = _resolve_item_id(db, line.item_id, line.other_item_name, line.other_item_unit)
        row = PhysicalDonation(
            user_id=first.user_id,
            guest_donor_id=first.guest_donor_id,
            report_id=first.report_id,
            item_id=item_id,
            **line_amounts(db, db.get(Item, item_id), line),
            estimated_value=line.estimated_value,
            handover_method=base.handover_method,
            pickup_address=base.pickup_address,
            pickup_lat=base.pickup_lat,
            pickup_lng=base.pickup_lng,
            pickup_landmark=base.pickup_landmark,
            pickup_notes=base.pickup_notes,
            pickup_days=base.pickup_days,
            pickup_dates=base.pickup_dates,
            pickup_not_home_date=base.pickup_not_home_date,
            preferred_pickup_at=base.preferred_pickup_at,
            qr_reference=f"{ref}-{k}",
            batch_reference=ref,
            addition_no=number,
            status="Pending",
        )
        k += 1
        db.add(row)
        new.append(row)
    set_deadline(new)
    if deadline is not None:
        for r in new:
            r.expires_at = deadline
    db.flush()
    log_action(db, current_user, "ADD DONATION ITEMS", "physical_donations", new[0].donation_id,
               new={"batch_reference": ref, "addition_no": number,
                    "items": [(r.item_id, r.quantity, r.packaging) for r in new]})
    notify_event_many(db, user_ids_with_role(db, ["CSWS Main Office"]), "donation_items_added",
                      "donation", new[0].donation_id, batch_no=ref, count=len(new),
                      addition_no=number)
    db.commit()
    return _batch_view(db, _batch_rows(db, ref), staff=False)


@router.post("/entries/{reference}/items/{donation_id}/remove")
def remove_item_from_entry(
    reference: str,
    donation_id: int,
    payload: DonationItemRemove,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    """Remove one waiting item, with a reason. It is closed, not deleted, so
    CSWS sees "Removed by donor: <reason>" when scanning and in its lists.
    The last open item of a donation cannot be removed."""
    rows = _own_rows(db, reference, current_user, "remove items from")
    row = next((r for r in rows if r.donation_id == donation_id), None)
    if row is None:
        raise HTTPException(status_code=404, detail="That item is not part of this donation.")
    if row.status != "Pending":
        raise HTTPException(status_code=409, detail="Only items still waiting can be removed.")
    if not any(r.status in ("Pending", "Received", "Confirmed")
               for r in rows if r.donation_id != donation_id):
        raise HTTPException(
            status_code=409,
            detail="A donation needs at least one item, so this item cannot be removed. "
                   "To withdraw the whole donation, cancel it instead.",
        )
    item = db.get(Item, row.item_id)
    close_rows([row], "Cancelled", f"{REMOVED_PREFIX}{payload.reason}", user_id=current_user.user_id)
    log_action(db, current_user, "REMOVE DONATION ITEM", "physical_donations", row.donation_id,
               old={"status": "Pending", "item_id": row.item_id, "quantity": row.quantity},
               new={"status": "Cancelled", "reason": payload.reason,
                    "batch_reference": row.batch_reference, "addition_no": row.addition_no or 1})
    notify_event_many(db, user_ids_with_role(db, ["CSWS Main Office"]), "donation_item_removed",
                      "donation", row.donation_id, batch_no=row.batch_reference,
                      item=item.item_name if item else "an item", reason=payload.reason)
    db.commit()
    return _batch_view(db, _batch_rows(db, row.batch_reference), staff=False)


@router.put("/entries/{reference}")
def edit_my_entry(
    reference: str,
    payload: DonationEntryEdit,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    """Change the items, the handover method or the pickup details. The QR
    reference stays the same, so a saved QR image still works. A donation
    that was declined (Cancelled) is waiting again after the change."""
    rows = _own_entry(db, reference, current_user, _DONOR_EDITABLE, "change")
    # This edit rewrites the whole item list. Once items were added later or
    # removed with a reason, that history must stay: use add / remove.
    if any((r.addition_no or 1) > 1 or is_removed(r) for r in rows):
        raise HTTPException(
            status_code=409,
            detail="Items were added to or removed from this donation, so it can no longer "
                   "be edited as a whole. Use Add items or remove single items instead.",
        )
    _check_service_area(payload)
    first = rows[0]
    ref = first.batch_reference
    before = {
        "handover_method": first.handover_method, "pickup_days": first.pickup_days,
        "pickup_dates": first.pickup_dates,
        "pickup_lat": _num(first.pickup_lat), "pickup_lng": _num(first.pickup_lng),
        "items": [(r.item_id, r.quantity, r.packaging) for r in rows],
        "statuses": sorted({r.status for r in rows}),
    }
    reopened = any(r.status == "Cancelled" for r in rows)
    days = encode_pickup_days(payload.pickup_days)
    dates = encode_pickup_dates(payload.pickup_dates)

    def apply(row, line):
        row.item_id = _resolve_item_id(db, line.item_id, line.other_item_name, line.other_item_unit)
        for field, value in line_amounts(db, db.get(Item, row.item_id), line).items():
            setattr(row, field, value)
        row.estimated_value = line.estimated_value
        row.handover_method = payload.handover_method
        row.pickup_address = payload.pickup_address
        row.pickup_lat = payload.pickup_lat
        row.pickup_lng = payload.pickup_lng
        row.pickup_landmark = payload.pickup_landmark
        row.pickup_notes = payload.pickup_notes
        row.pickup_days = days
        row.pickup_dates = dates
        row.preferred_pickup_at = payload.preferred_pickup_at
        row.status = "Pending"
        row.closed_at = None
        row.close_reason = None
        row.closed_by_user_id = None

    kept = rows[:len(payload.items)]
    for row, line in zip(kept, payload.items):
        apply(row, line)
    for row in rows[len(payload.items):]:
        db.delete(row)  # Pending / Cancelled only: nothing refers to it
    next_n = max(int(r.qr_reference.rsplit("-", 1)[-1]) if r.qr_reference.rsplit("-", 1)[-1].isdigit() else 0
                 for r in rows) + 1
    for line in payload.items[len(kept):]:
        row = PhysicalDonation(
            user_id=first.user_id, guest_donor_id=first.guest_donor_id,
            report_id=first.report_id, item_id=0, packaging="", quantity=1,
            handover_method=payload.handover_method,
            qr_reference=f"{ref}-{next_n}", batch_reference=ref, status="Pending",
            created_at=first.created_at,
        )
        next_n += 1
        apply(row, line)
        db.add(row)
        kept.append(row)
    # A changed donation keeps its original deadline; a declined one that
    # is fixed gets a fresh one from today.
    set_deadline(kept, start=now_utc() if reopened else first.created_at)
    if (before["handover_method"] != payload.handover_method or before["pickup_days"] != days
            or before["pickup_dates"] != dates
            or before["pickup_lat"] != payload.pickup_lat or before["pickup_lng"] != payload.pickup_lng):
        _drop_from_pickup_runs(db, ref)
    db.flush()
    log_action(db, current_user, "EDIT DONATION", "physical_donations", kept[0].donation_id,
               old=before, new={
                   "handover_method": payload.handover_method, "pickup_days": days,
                   "pickup_dates": dates,
                   "items": [(r.item_id, r.quantity, r.packaging) for r in kept],
                   "reopened": reopened,
               })
    db.commit()
    return _batch_view(db, _batch_rows(db, ref), staff=False)


@router.delete("/entries/{reference}")
def delete_my_entry(
    reference: str,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    """Remove a donation nothing of which was received yet. It disappears
    from the donor's and the staff's lists, with its notifications; the
    audit log keeps what it was."""
    rows = _own_entry(db, reference, current_user, _DONOR_DELETABLE, "delete")
    ref = rows[0].batch_reference
    ids = [r.donation_id for r in rows]
    log_action(db, current_user, "DELETE DONATION", "physical_donations", ids[0], old={
        "batch_reference": ref, "report_id": rows[0].report_id,
        "handover_method": rows[0].handover_method,
        "items": [(r.item_id, r.quantity, r.packaging, r.status) for r in rows],
    })
    _drop_from_pickup_runs(db, ref)
    db.query(Notification).filter(
        Notification.entity_type == "donation", Notification.entity_id.in_(ids)
    ).delete(synchronize_session=False)
    for r in rows:
        db.delete(r)
    db.commit()
    return {"batch_reference": ref, "deleted_items": len(ids)}


# ---------------------------------------------------------------------------
# QR codes
# ---------------------------------------------------------------------------
@router.get("/batch/{reference}/qr")
def get_batch_qr(reference: str, db: Session = Depends(get_db)):
    """Re-show a donation's QR. Public like /{id}/qr: it returns only the
    reference and the QR image, no donor or address details."""
    rows = _batch_rows(db, reference)
    ref = rows[0].batch_reference
    return {"batch_reference": ref, "qr_image_base64": _qr_b64(ref)}


@router.get("/{donation_id}/qr")
def get_donation_qr(donation_id: int, db: Session = Depends(get_db)):
    donation = db.query(PhysicalDonation).filter(PhysicalDonation.donation_id == donation_id).first()
    if not donation:
        raise HTTPException(status_code=404, detail="Donation not found")
    # The QR always holds the donation's shared reference.
    ref = donation.batch_reference or donation.qr_reference
    return {
        "qr_reference": donation.qr_reference,
        "batch_reference": ref,
        "qr_image_base64": _qr_b64(ref),
    }


# ---------------------------------------------------------------------------
# UC-CM1 step 2: CSWS opens a donation from its QR
# ---------------------------------------------------------------------------
@router.get("/by-batch/{reference}")
def find_by_batch(
    reference: str,
    db: Session = Depends(get_db),
    current_user: User = Depends(require_role(*CSWS_ROLES)),
):
    """Every item of the scanned donation. Each item is then received on its
    own through POST /donations/receive (UC-CM1 steps 3-8, alt 4a/4b)."""
    expire_overdue(db)  # an overdue scan shows "Expired" with the Reinstate option
    return _batch_view(db, _batch_rows(db, reference), staff=True)


# ---------------------------------------------------------------------------
# Door to Door pickup board (Phase 1): every donation that still has goods
# waiting to be collected, soonest preferred pickup first. Lets CSWS plan
# pickups without opening each donation (UC-CM1 for Door to Door).
# ---------------------------------------------------------------------------
@router.get("/pickups")
def door_to_door_pickups(
    db: Session = Depends(get_db),
    current_user: User = Depends(require_role(*PICKUP_ROLES)),
):
    expire_overdue(db)  # overdue pickups leave the board
    waiting = (
        db.query(PhysicalDonation.batch_reference)
        .filter(
            PhysicalDonation.handover_method == "Door to Door",
            PhysicalDonation.status == "Pending",
        )
        .distinct()
        .all()
    )
    refs = [r[0] for r in waiting]
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

    out = []
    for ref, lines in by_ref.items():
        first = lines[0]
        if first.report_id not in labels:
            labels[first.report_id] = _report_label(db, first.report_id)
        pending = [l for l in lines if l.status == "Pending"]
        summary = []
        for l in lines:
            it = items.get(l.item_id)
            unit = it.unit_of_measure if it else ""
            name = it.item_name if it else "Item"
            summary.append(f"{l.quantity} {unit} {name}".replace("  ", " ").strip())
        out.append({
            "batch_reference": ref,
            "status": _batch_status({l.status for l in lines}),
            "preferred_pickup_at": _iso(first.preferred_pickup_at),
            "pickup_address": first.pickup_address,
            "pickup_lat": _num(first.pickup_lat),
            "pickup_lng": _num(first.pickup_lng),
            "pickup_landmark": first.pickup_landmark,
            "pickup_notes": first.pickup_notes,
            **_pickup_days_view(first),
            **_distance_view(first),
            "report_id": first.report_id,
            "report_label": labels[first.report_id],
            "total_items": len(lines),
            "pending_items": len(pending),
            "items_summary": summary,
            "created_at": first.created_at,
            **entry_expiry_info(lines),
            **_donor_info(db, first),
        })

    # Pickup runs already sent to DRRMO, so the map can mark those stops.
    runs = {}
    for req in (db.query(LogisticsRequest)
                .filter(LogisticsRequest.request_type == "Pickup",
                        LogisticsRequest.status.in_(("Pending", "Accepted"))).all()):
        for ref in req.batch_list:
            runs[ref] = {
                "request_id": req.request_id,
                "status": req.status,
                "pickup_date": req.pickup_date.isoformat() if req.pickup_date else None,
            }
    for b in out:
        b["pickup_request"] = runs.get(b["batch_reference"])

    # Soonest preferred time first; donations without a time go last.
    out.sort(key=lambda b: (b["preferred_pickup_at"] is None,
                            b["preferred_pickup_at"] or "",
                            str(b["created_at"])))
    return out


# ---------------------------------------------------------------------------
# UC-D2 alt 7b: storage address and drop-off instructions
# ---------------------------------------------------------------------------
@router.get("/drop-off-info")
def drop_off_info():
    def coord(name):
        raw = os.getenv(name)
        try:
            return float(raw) if raw else None
        except ValueError:
            return None

    lat, lng = coord("DROPOFF_LAT"), coord("DROPOFF_LNG")
    if lat is None or lng is None:
        lat = lng = None
    return {
        "name": os.getenv("DROPOFF_NAME", "City of Mandaue City Social Services (CSWS)"),
        "address": os.getenv("DROPOFF_ADDRESS", "City of Mandaue City Social Services (CSWS), Mandaue City"),
        "hours": os.getenv("DROPOFF_HOURS", "Monday to Friday, 8:00 AM to 5:00 PM"),
        "instructions": os.getenv(
            "DROPOFF_INSTRUCTIONS",
            "Bring the goods and show your QR code. CSWS will count what "
            "arrives and record the actual quantity.",
        ),
        "lat": lat,
        "lng": lng,
    }


# ---------------------------------------------------------------------------
# UC-D2 alt 7c: when CSWS does Door to Door pickups (the app's date picker
# only offers these days and hours; the server checks them again).
# ---------------------------------------------------------------------------
@router.get("/pickup-rules")
def get_pickup_rules():
    area = pickup_area()
    return {**pickup_rules_view(), "area": {
        "name": area["name"], "bbox": area["bbox"],
        "office_lat": area["office"][0], "office_lng": area["office"][1],
        "max_km": area["max_km"],
    }}


# ---------------------------------------------------------------------------
# UC-D2 alt 7c: address suggestions for Door to Door pickups.
# OpenStreetMap data via Photon. Called from the backend so results can be
# cached (fair use of the free public server) and the provider can be
# swapped by changing GEOCODER_URL only. Public because guests donate too.
# ---------------------------------------------------------------------------
def _geocoder(path: str, params: dict) -> dict:
    base = os.getenv("GEOCODER_URL", "https://photon.komoot.io").rstrip("/")
    agent = os.getenv("GEOCODER_USER_AGENT", "NexaAid/1.0 (Mandaue City disaster relief system)")
    key = (base, path, tuple(sorted(params.items())))
    now = time.time()
    hit = _GEO_CACHE.get(key)
    if hit and now - hit[0] < _GEO_CACHE_TTL:
        return hit[1]
    try:
        r = httpx.request(
            "GET", f"{base}{path}", params=params,
            headers={"User-Agent": agent}, timeout=8.0,
        )
    except httpx.HTTPError:
        raise HTTPException(
            status_code=502,
            detail="Address suggestions are unavailable right now. Type the full address yourself.",
        )
    if r.status_code != 200:
        raise HTTPException(
            status_code=502,
            detail="Address suggestions are unavailable right now. Type the full address yourself.",
        )
    data = r.json()
    if len(_GEO_CACHE) >= _GEO_CACHE_MAX:
        _GEO_CACHE.pop(next(iter(_GEO_CACHE)))
    _GEO_CACHE[key] = (now, data)
    return data


def _describe(props: dict) -> tuple:
    """(main, secondary, full address) from a Photon feature's properties."""
    street = " ".join(p for p in (props.get("housenumber"), props.get("street")) if p)
    name = props.get("name")
    main = name or street or props.get("district") or props.get("city") or "Unnamed place"
    parts = []
    for part in (
        street if name else None,
        props.get("locality"),
        props.get("district"),
        props.get("city"),
        props.get("county"),
        props.get("state"),
    ):
        if part and part != main and part not in parts:
            parts.append(part)
    secondary = ", ".join(parts)
    return main, secondary, ", ".join([main] + parts)


@router.get("/location/autocomplete")
def location_autocomplete(q: str = Query(min_length=2, max_length=200)):
    data = _geocoder("/api", {
        "q": q.strip(),
        "limit": 8,
        "lat": SEARCH_CENTER[0],
        "lon": SEARCH_CENTER[1],
        "bbox": SEARCH_BBOX,
    })
    out = []
    seen = set()
    for f in data.get("features", []):
        coords = (f.get("geometry") or {}).get("coordinates") or []
        if len(coords) < 2:
            continue
        props = f.get("properties") or {}
        main, secondary, full = _describe(props)
        if full.lower() in seen:
            continue  # OSM can store one place as both a point and a building
        seen.add(full.lower())
        out.append({
            "place_id": f"{props.get('osm_type', '')}{props.get('osm_id', '')}",
            "main": main,
            "secondary": secondary,
            "address": full,
            "lat": coords[1],
            "lng": coords[0],
        })
    return out


def pin_coverage(text: Optional[str], lat: Optional[float], lng: Optional[float]) -> dict:
    """Is this Door to Door pickup inside the service areas?
    1. The landmark text (an OpenStreetMap address, so it names the town).
    2. If that does not name a served place and there is a pin: ask the map
       which town the pin is in (reverse lookup), and check that.
    If the map lookup is down, the text answer stands."""
    place = place_in(text)
    if in_service_area(text):
        return {"covered": True, "place": place}
    if lat is not None and lng is not None:
        try:
            data = _geocoder("/reverse", {"lat": round(lat, 5), "lon": round(lng, 5), "limit": 1})
        except HTTPException:
            data = {}
        features = data.get("features") or []
        if features:
            props = features[0].get("properties") or {}
            full = _describe(props)[2]
            place = props.get("city") or props.get("county") or place_in(full) or place
            if in_service_area(full):
                return {"covered": True, "place": place}
    return {"covered": False, "place": place}


def _out_of_area_message(place: Optional[str]) -> str:
    where = f"from {place}" if place else "from this location"
    return (f"Sorry, door-to-door pickup is not available {where} yet. It only covers "
            f"{service_areas_label()} for now. Please choose Drop Off and bring your "
            "donation to the CSWS collection point.")


def _check_service_area(payload) -> None:
    """Door to Door only inside the service areas (Mandaue City, northern
    Cebu City, Consolacion, Lapu-Lapu City). The landmark decides when given
    (it carries the map pin); otherwise the typed address."""
    if payload.handover_method != "Door to Door":
        return
    where = pin_coverage(payload.pickup_landmark or payload.pickup_address,
                         payload.pickup_lat, payload.pickup_lng)
    if not where["covered"]:
        raise HTTPException(status_code=422, detail=_out_of_area_message(where["place"]))


@router.get("/location/coverage")
def location_coverage(
    text: str = Query(default="", max_length=500),
    lat: Optional[float] = Query(default=None, ge=-90, le=90),
    lng: Optional[float] = Query(default=None, ge=-180, le=180),
):
    """The donate form asks this as soon as a landmark is picked, so the
    donor learns right away whether Door to Door is possible there."""
    where = pin_coverage(text, lat, lng)
    return {
        **where,
        "areas_label": service_areas_label(),
        "message": None if where["covered"] else _out_of_area_message(where["place"]),
    }


@router.get("/location/reverse")
def location_reverse(
    lat: float = Query(ge=-90, le=90),
    lng: float = Query(ge=-180, le=180),
):
    # Rounded to ~1 m so tiny pin jitters share a cache entry.
    data = _geocoder("/reverse", {"lat": round(lat, 5), "lon": round(lng, 5), "limit": 1})
    features = data.get("features") or []
    address = _describe(features[0].get("properties") or {})[2] if features else None
    return {"address": address or f"{lat:.5f}, {lng:.5f}", "lat": lat, "lng": lng}


# ---------------------------------------------------------------------------
# UC-D3 / UC-D4 / UC-R3 / UC-R4: the donor's own records
# ---------------------------------------------------------------------------
@router.get("/mine")
def my_donations(
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    """Donor / Relief Organization dashboard (manuscript UC-D3, UC-D4,
    UC-R3, UC-R4): the user's own donation history and status, the reports
    they supported, and those reports' fulfillment progress."""
    expire_overdue(db)
    donations = (
        db.query(PhysicalDonation)
        .filter(PhysicalDonation.user_id == current_user.user_id)
        .order_by(PhysicalDonation.donation_id.desc())
        .all()
    )
    # 6.2: the CMO's latest decision per donation, so the donor can see an
    # "On Hold" status and the reason the CMO gave. Imported here (not at the
    # top of the file) to avoid a circular import between the two routers.
    from api.v1.cmo_router import _latest_decisions
    decisions = _latest_decisions(db, [d.donation_id for d in donations])

    items = {i.item_id: i for i in db.query(Item).all()}
    types = {t.disaster_type_id: t.type_name for t in db.query(DisasterType).all()}
    barangays = {b.barangay_id: b.barangay_name for b in db.query(Barangay).all()}
    report_ids = {d.report_id for d in donations}
    reports = {
        r.report_id: r
        for r in db.query(DisasterReport).filter(DisasterReport.report_id.in_(report_ids)).all()
    } if report_ids else {}

    def report_info(r):
        f = r.fulfillment
        return {
            "report_id": r.report_id,
            "label": f"{types.get(r.disaster_type_id, 'Disaster')} in {barangays.get(r.barangay_id, 'Barangay')}",
            "disaster": types.get(r.disaster_type_id, "Disaster"),
            "barangay": barangays.get(r.barangay_id, "Barangay"),
            "assistance_needed": r.assistance_needed,
            "status": r.status,
            "priority_level": r.priority_level,
            "total_items_needed": f.total_items_needed if f else r.estimated_quantity,
            "total_items_delivered": f.total_items_delivered if f else 0,
            "fulfillment_percentage": float(f.fulfillment_percentage) if f else 0.0,
        }

    entries = build_entries(db, donations, include_cmo=True)
    group_by_report(entries)  # numbers each report's entries (Donation 1, 2 ...)
    # Oct 13: In transit / Delivered / Barangay confirmed on the donor's own
    # timeline, from whose goods went on each delivery.
    add_delivery_progress(db, entries)
    by_ref = {}
    rows_by_ref: dict = {}
    for d in donations:
        by_ref[d.batch_reference] = d  # rows are newest first, so this keeps the entry's first row
        rows_by_ref.setdefault(d.batch_reference, []).append(d)
    # Oct 23: can the donor still add or remove items (and if not, why)?
    blocked_by_ref = {
        ref: change_blocked(reports.get(rs[0].report_id), rs) for ref, rs in rows_by_ref.items()
    }

    org = db.get(Organization, current_user.organization_id) if current_user.organization_id else None
    by_status = {}
    for d in donations:
        by_status[d.status] = by_status.get(d.status, 0) + 1

    return {
        "profile": {
            "name": f"{current_user.first_name} {current_user.last_name}".strip(),
            "email": current_user.email,
            "role": current_user.role.role_name,
            "organization": org.org_name if org else None,
            # Shown under the organization's name on its dashboard (Ivan).
            "organization_type": org.organization_type if org else None,
            "account_status": org.status if org else "Active",
            # Door to Door: donors "select his/her address" (manuscript 3.1).
            "address": org.address if org else None,
        },
        "summary": {
            "total_donations": len(donations),
            "pending": by_status.get("Pending", 0),
            "received": by_status.get("Received", 0),
            "confirmed": by_status.get("Confirmed", 0),
            "expired": by_status.get("Expired", 0),
            "cancelled": by_status.get("Cancelled", 0),
            "total_quantity": sum(d.quantity for d in donations),
            "supported_reports": len(report_ids),
            "total_batches": len({d.batch_reference for d in donations}),
            "total_entries": len(entries),
        },
        "donations": [
            {
                "donation_id": d.donation_id,
                "qr_reference": d.qr_reference,
                "batch_reference": d.batch_reference,
                "item_name": items[d.item_id].item_name if d.item_id in items else "Item",
                "unit": items[d.item_id].unit_of_measure if d.item_id in items else "",
                "quantity": d.quantity,
                "packaging": d.packaging,
                "handover_method": d.handover_method,
                "pickup_address": d.pickup_address,
                "pickup_landmark": d.pickup_landmark,
                "pickup_notes": d.pickup_notes,
                **_pickup_days_view(d),
                "preferred_pickup_at": _iso(d.preferred_pickup_at),
                "status": d.status,
                "close_reason": d.close_reason,
                # 6.2: latest CMO decision, and the reason only while it is On Hold
                "cmo_decision": decisions[d.donation_id].status if d.donation_id in decisions else None,
                "hold_reason": (
                    decisions[d.donation_id].notes
                    if d.donation_id in decisions and decisions[d.donation_id].status == "On Hold"
                    else None
                ),
                "created_at": d.created_at,
                "report": report_info(reports[d.report_id]) if d.report_id in reports else None,
            }
            for d in donations
        ],
        "supported_reports": [report_info(r) for r in reports.values()],
        # Ivan (donor Reports tab): delivery status. Donated goods go into
        # CSWS inventory and are delivered per report, so a delivery is not
        # tied to one donation. These are the deliveries to the reports this
        # user donated to, newest first, cancelled ones left out.
        "deliveries": _deliveries_to(db, list(report_ids), types, barangays),
        # 4.4 / 4.5: the same donations as entries (one per QR), newest first.
        "entries": [
            {
                **e,
                "pickup_address": by_ref[e["batch_reference"]].pickup_address,
                "pickup_landmark": by_ref[e["batch_reference"]].pickup_landmark,
                "pickup_lat": _num(by_ref[e["batch_reference"]].pickup_lat),
                "pickup_lng": _num(by_ref[e["batch_reference"]].pickup_lng),
                "pickup_notes": by_ref[e["batch_reference"]].pickup_notes,
                **_pickup_days_view(by_ref[e["batch_reference"]]),
                "preferred_pickup_at": _iso(by_ref[e["batch_reference"]].preferred_pickup_at),
                "report": report_info(reports[e["report_id"]]) if e["report_id"] in reports else None,
                "can_change_items": blocked_by_ref.get(e["batch_reference"]) is None,
                "change_blocked_reason": blocked_by_ref.get(e["batch_reference"]),
            }
            for e in filter_and_sort(entries)
        ],
    }


def _deliveries_to(db: Session, report_ids: list, types: dict, barangays: dict) -> list:
    if not report_ids:
        return []
    rows = (
        db.query(Delivery)
        .filter(Delivery.report_id.in_(report_ids), Delivery.status != "Cancelled")
        .order_by(Delivery.delivery_date.desc(), Delivery.delivery_id.desc())
        .limit(20)
        .all()
    )
    out = []
    for d in rows:
        names = [i.item.item_name for i in d.items if i.item is not None]
        summary = (
            "Relief goods" if not names
            else names[0] if len(names) == 1
            else f"{names[0]} and {len(names) - 1} more"
        )
        r = d.report
        out.append({
            "delivery_id": d.delivery_id,
            "report_id": d.report_id,
            "report_label": (
                f"{types.get(r.disaster_type_id, 'Disaster')} in "
                f"{barangays.get(r.barangay_id, 'Barangay')}" if r else None
            ),
            "barangay": d.destination_barangay.barangay_name if d.destination_barangay else None,
            "status": d.status,  # Preparing, In Transit, Delivered, Confirmed
            "items_summary": summary,
            "total_quantity": sum(i.quantity or 0 for i in d.items),
            "delivery_date": _iso(d.delivery_date),
            "confirmed_at": _iso(d.receipt.received_at) if d.receipt else None,
        })
    return out


# ---------------------------------------------------------------------------
# Entry-based view: Report -> Entries (one per QR) -> Items.
# Staff see every entry; donors and relief orgs only their own.
# ---------------------------------------------------------------------------
ENTRY_STAFF_ROLES = ("Administrator", "CSWS Main Office", "CMO Representative")


@router.get("/entries")
def donation_entries(
    report_id: Optional[int] = None,
    pending_only: bool = False,
    db: Session = Depends(get_db),
    current_user: User = Depends(
        require_role(*ENTRY_STAFF_ROLES, "Individual Donor", "Relief Organization")
    ),
):
    staff = has_role(current_user, *ENTRY_STAFF_ROLES)
    expire_overdue(db)
    query = db.query(PhysicalDonation)
    if not staff:
        query = query.filter(PhysicalDonation.user_id == current_user.user_id)
    if report_id is not None:
        query = query.filter(PhysicalDonation.report_id == report_id)
    entries = build_entries(db, query.all(), include_donor=staff)
    reports = group_by_report(entries, pending_only=pending_only)
    return {
        "total_reports": len(reports),
        "total_entries": sum(r["total_entries"] for r in reports),
        "reports": reports,
    }