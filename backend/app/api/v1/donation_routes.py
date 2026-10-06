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
from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy.orm import Session

from core.database import get_db
from core.auth import get_current_user, get_current_user_optional, has_role, require_role
from models.user_rbac_model import User
from models.guest_donor_model import GuestDonor
from models.physical_donation_model import PhysicalDonation
from models.received_goods_model import ReceivedGoods
from models.item_model import Item
from models.organization_model import Organization
from models.report import DisasterReport, DisasterType, Barangay
from schemas.physical_donation_schema import (
    DonationBatchCreate,
    PhysicalDonationCreate,
    PhysicalDonationResponse,
    pickup_rules,
)
from core.notifications import notify_event, notify_event_many, user_ids_with_role
from services.donation_entries import build_entries, group_by_report

router = APIRouter(prefix="/donations", tags=["Physical Donations"])

CSWS_ROLES = ("CSWS Main Office", "Administrator")

# Address search (UC-D2 alt 7c) uses OpenStreetMap data through Photon:
# free, no API key, no billing. GEOCODER_URL can point to a self-hosted
# Photon server later without any app change.
SEARCH_CENTER = (10.3300, 123.9300)             # (lat, lng) Mandaue City centre: results near here rank first
SEARCH_BBOX = "123.25,9.40,124.10,11.30"        # minLon,minLat,maxLon,maxLat: all of Cebu province
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
    if item_id is not None:
        if db.get(Item, item_id) is None:
            raise HTTPException(status_code=404, detail=f"Item {item_id} not found")
        return item_id
    # "Other" item: reuse it if it already exists, else add it to the list.
    name = other_name.strip()
    item = db.query(Item).filter(Item.item_name.ilike(name)).first()
    if item is None:
        item = Item(
            item_name=name,
            category="Other",
            unit_of_measure=(other_unit or "pcs").strip() or "pcs",
        )
        db.add(item)
        db.flush()
    return item.item_id


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


def _batch_status(statuses: set) -> str:
    if len(statuses) == 1:
        return next(iter(statuses))
    if "Pending" in statuses:
        return "Partly Received"
    return "Received"


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


def _batch_view(db: Session, rows: list, staff: bool) -> dict:
    first = rows[0]
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
        "handover_method": first.handover_method,
        "pickup_address": first.pickup_address,
        "pickup_lat": _num(first.pickup_lat),
        "pickup_lng": _num(first.pickup_lng),
        "pickup_landmark": first.pickup_landmark,
        "preferred_pickup_at": _iso(first.preferred_pickup_at),
        "created_at": first.created_at,
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
                "estimated_value": _num(r.estimated_value),
                "status": r.status,
                "actual_quantity_received": received.get(r.donation_id),
            }
            for r in rows
        ],
    }
    if staff:
        view.update(_donor_info(db, first))
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
    user_id, guest_donor_id = _donor_ids(db, current_user, payload.guest_donor)

    batch_reference = _new_reference()
    rows = []
    for n, line in enumerate(payload.items, start=1):
        row = PhysicalDonation(
            user_id=user_id,
            guest_donor_id=guest_donor_id,
            report_id=payload.report_id,
            item_id=_resolve_item_id(db, line.item_id, line.other_item_name, line.other_item_unit),
            packaging=line.packaging,
            quantity=line.quantity,
            estimated_value=line.estimated_value,
            handover_method=payload.handover_method,
            pickup_address=payload.pickup_address,
            pickup_lat=payload.pickup_lat,
            pickup_lng=payload.pickup_lng,
            pickup_landmark=payload.pickup_landmark,
            preferred_pickup_at=payload.preferred_pickup_at,
            qr_reference=f"{batch_reference}-{n}",
            batch_reference=batch_reference,
            status="Pending",
        )
        db.add(row)
        rows.append(row)
    db.flush()  # assigns donation_id for the notifications

    if current_user:  # guest donors have no account
        notify_event(db, current_user.user_id, "donation_submitted_confirm",
                     "donation", rows[0].donation_id, batch_no=batch_reference)
    notify_event_many(db, user_ids_with_role(db, ["CSWS Main Office"]),
                      "donation_submitted", None, None, batch_no=batch_reference)

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
    user_id, guest_donor_id = _donor_ids(db, current_user, payload.guest_donor)
    reference = _new_reference()

    donation = PhysicalDonation(
        user_id=user_id,
        guest_donor_id=guest_donor_id,
        report_id=payload.report_id,
        item_id=_resolve_item_id(db, payload.item_id, payload.other_item_name, payload.other_item_unit),
        packaging=payload.packaging,
        quantity=payload.quantity,
        estimated_value=payload.estimated_value,
        handover_method=payload.handover_method,
        pickup_address=payload.pickup_address,
        pickup_lat=payload.pickup_lat,
        pickup_lng=payload.pickup_lng,
        pickup_landmark=payload.pickup_landmark,
        preferred_pickup_at=payload.preferred_pickup_at,
        qr_reference=reference,
        batch_reference=reference,
        status="Pending",
    )
    db.add(donation)
    db.flush()  # assigns donation_id for the notifications

    if current_user:  # guest donors have no account
        notify_event(db, current_user.user_id, "donation_submitted_confirm",
                     "donation", donation.donation_id, batch_no=donation.donation_id)
    notify_event_many(db, user_ids_with_role(db, ["CSWS Main Office"]),
                      "donation_submitted", None, None, batch_no=donation.donation_id)

    db.commit()
    db.refresh(donation)
    return donation


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
    return _batch_view(db, _batch_rows(db, reference), staff=True)


# ---------------------------------------------------------------------------
# Door to Door pickup board (Phase 1): every donation that still has goods
# waiting to be collected, soonest preferred pickup first. Lets CSWS plan
# pickups without opening each donation (UC-CM1 for Door to Door).
# ---------------------------------------------------------------------------
@router.get("/pickups")
def door_to_door_pickups(
    db: Session = Depends(get_db),
    current_user: User = Depends(require_role(*CSWS_ROLES)),
):
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
            "pickup_notes": first.pickup_landmark,
            "report_id": first.report_id,
            "report_label": labels[first.report_id],
            "total_items": len(lines),
            "pending_items": len(pending),
            "items_summary": summary,
            "created_at": first.created_at,
            **_donor_info(db, first),
        })

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
    return pickup_rules()


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
            "status": r.status,
            "priority_level": r.priority_level,
            "total_items_needed": f.total_items_needed if f else r.estimated_quantity,
            "total_items_delivered": f.total_items_delivered if f else 0,
            "fulfillment_percentage": float(f.fulfillment_percentage) if f else 0.0,
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
            "account_status": org.status if org else "Active",
            # Door to Door: donors "select his/her address" (manuscript 3.1).
            "address": org.address if org else None,
        },
        "summary": {
            "total_donations": len(donations),
            "pending": by_status.get("Pending", 0),
            "received": by_status.get("Received", 0),
            "confirmed": by_status.get("Confirmed", 0),
            "total_quantity": sum(d.quantity for d in donations),
            "supported_reports": len(report_ids),
            "total_batches": len({d.batch_reference for d in donations}),
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
                "preferred_pickup_at": _iso(d.preferred_pickup_at),
                "status": d.status,
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
    }
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

