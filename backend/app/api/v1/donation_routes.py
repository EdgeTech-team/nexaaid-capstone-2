"""Physical donations (manuscript UC-D2, Physical Donation module, UC-D3/D4,
UC-R3/R4) plus the CSWS lookup of one donation by its QR (UC-CM1 step 2).

One donation = one QR reference (batch_reference), however many items.
Every item is still its own physical_donations row, so receiving, CMO
confirmation, inventory and deliveries keep working per item.
"""
import base64
import io
import os
import uuid
from typing import Optional

import httpx
import qrcode
from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy.orm import Session

from core.database import get_db
from core.auth import get_current_user, get_current_user_optional, require_role
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
)

router = APIRouter(prefix="/donations", tags=["Physical Donations"])

CSWS_ROLES = ("CSWS Main Office", "Administrator")

# Cebu City centre, used to bias address search toward the service area.
CEBU_CITY = {"latitude": 10.3157, "longitude": 123.8854}
SEARCH_RADIUS_M = 25000.0


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
    if d.user_id:
        u = db.get(User, d.user_id)
        if u is None:
            return {"donor": "Donor", "donor_contact": None}
        org = db.get(Organization, u.organization_id) if u.organization_id else None
        name = f"{u.first_name} {u.last_name}".strip()
        return {
            "donor": f"{name} ({org.org_name})" if org else name,
            "donor_contact": u.contact_number,
        }
    g = db.get(GuestDonor, d.guest_donor_id) if d.guest_donor_id else None
    return {
        "donor": f"{g.full_name} (guest)" if g else "Guest",
        "donor_contact": g.contact_number if g else None,
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
            qr_reference=f"{batch_reference}-{n}",
            batch_reference=batch_reference,
            status="Pending",
        )
        db.add(row)
        rows.append(row)

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
        qr_reference=reference,
        batch_reference=reference,
        status="Pending",
    )
    db.add(donation)
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
        "name": os.getenv("DROPOFF_NAME", "CSWS Main Office"),
        "address": os.getenv("DROPOFF_ADDRESS", "CSWS Main Office, Cebu City"),
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
# UC-D2 alt 7c: address search and map pin for Door to Door pickups.
# Google is called from here so the API key never ships inside the app.
# Public because guest donors use the form too.
# ---------------------------------------------------------------------------
def _maps_key() -> str:
    key = os.getenv("GOOGLE_MAPS_SERVER_KEY")
    if not key:
        raise HTTPException(
            status_code=503,
            detail="Address search is not set up. Type the address instead.",
        )
    return key


def _google(method: str, url: str, **kwargs) -> dict:
    try:
        r = httpx.request(method, url, timeout=8.0, **kwargs)
    except httpx.HTTPError:
        raise HTTPException(status_code=502, detail="Map service unreachable. Type the address instead.")
    if r.status_code != 200:
        raise HTTPException(status_code=502, detail="Map service error. Type the address instead.")
    return r.json()


@router.get("/location/autocomplete")
def location_autocomplete(
    q: str = Query(min_length=2, max_length=200),
    session: Optional[str] = Query(default=None, max_length=64),
):
    body = {
        "input": q,
        "includedRegionCodes": ["ph"],
        "locationBias": {"circle": {"center": CEBU_CITY, "radius": SEARCH_RADIUS_M}},
    }
    if session:
        body["sessionToken"] = session
    data = _google(
        "POST",
        "https://places.googleapis.com/v1/places:autocomplete",
        json=body,
        headers={"X-Goog-Api-Key": _maps_key()},
    )
    out = []
    for s in data.get("suggestions", []):
        p = s.get("placePrediction")
        if not p:
            continue
        fmt = p.get("structuredFormat", {})
        out.append({
            "place_id": p.get("placeId"),
            "main": fmt.get("mainText", {}).get("text") or p.get("text", {}).get("text", ""),
            "secondary": fmt.get("secondaryText", {}).get("text", ""),
        })
    return out


@router.get("/location/place/{place_id}")
def location_place(
    place_id: str,
    session: Optional[str] = Query(default=None, max_length=64),
):
    data = _google(
        "GET",
        f"https://places.googleapis.com/v1/places/{place_id}",
        params={"sessionToken": session} if session else None,
        headers={
            "X-Goog-Api-Key": _maps_key(),
            "X-Goog-FieldMask": "displayName,formattedAddress,location",
        },
    )
    loc = data.get("location")
    if not loc:
        raise HTTPException(status_code=404, detail="Place not found")
    return {
        "name": data.get("displayName", {}).get("text"),
        "address": data.get("formattedAddress"),
        "lat": loc["latitude"],
        "lng": loc["longitude"],
    }


@router.get("/location/reverse")
def location_reverse(
    lat: float = Query(ge=-90, le=90),
    lng: float = Query(ge=-180, le=180),
):
    data = _google(
        "GET",
        "https://maps.googleapis.com/maps/api/geocode/json",
        params={"latlng": f"{lat},{lng}", "key": _maps_key(), "region": "ph"},
    )
    if data.get("status") not in ("OK", "ZERO_RESULTS"):
        raise HTTPException(status_code=502, detail="Map service error. Type the address instead.")
    results = data.get("results") or []
    address = results[0].get("formatted_address") if results else None
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
                "status": d.status,
                "created_at": d.created_at,
                "report": report_info(reports[d.report_id]) if d.report_id in reports else None,
            }
            for d in donations
        ],
        "supported_reports": [report_info(r) for r in reports.values()],
    }