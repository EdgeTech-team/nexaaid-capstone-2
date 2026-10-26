"""Ending a donation that will not be handed over: cancel, expire, reinstate.

Rules and reasons: services/donation_expiry.py (team decision Oct 9, 2026,
an addition to manuscript 3.2 "Pending donation records").

    GET  /donations/expiry-rules                 deadlines in plain words (public)
    POST /donations/entries/{ref}/cancel         donor, guest (with phone), or CSWS
    POST /donations/entries/{ref}/reinstate      CSWS / Admin: back to Pending
    POST /donations/expiry/run                   CSWS / Admin, or a cron with a token
"""
import hmac
import os
from datetime import datetime
from typing import Optional

from fastapi import APIRouter, Depends, Header, HTTPException
from pydantic import BaseModel, Field, field_validator
from sqlalchemy.orm import Session

from core.audit import log_action
from core.auth import (
    check_guest_cancel_attempts, get_current_user_optional, has_role,
    record_guest_cancel_failure, require_role,
)
from core.database import get_db
from core.notifications import notify_event, notify_event_many, user_ids_with_role
from models.guest_donor_model import GuestDonor
from models.physical_donation_model import PhysicalDonation
from models.user_rbac_model import User
from schemas.physical_donation_schema import check_preferred_pickup, normalize_ph_mobile
from services.donation_expiry import (
    CLOSED, OPEN, close_rows, expire_overdue, expiry_rules, nice_date, reopen_rows,
)
from services.donation_additions import is_removed

router = APIRouter(prefix="/donations", tags=["Donation expiry and cancellation"])

STAFF = ("CSWS Main Office", "Administrator")

# Offered as one-tap choices in the app; anything else can be typed.
CANCEL_REASONS = [
    "I changed my mind",
    "The items are no longer available",
    "I gave the items another way",
    "I cannot bring them in time",   
]

# F-17: every failed guest attempt (wrong, missing or invalid phone number,
# or a donation made from an account) gets this same answer.
GUEST_CANCEL_FAILED = "Log in, or enter the phone number you used when donating."



class CancelRequest(BaseModel):
    reason: Optional[str] = Field(default=None, max_length=300)
    # Guests have no account: they prove it is theirs with the phone number
    # they gave when donating.
    contact_number: Optional[str] = None


class ReinstateRequest(BaseModel):
    note: Optional[str] = Field(default=None, max_length=300)
    # Door to Door: a new pickup time if the old one has passed.
    preferred_pickup_at: Optional[datetime] = None

    @field_validator("preferred_pickup_at")
    @classmethod
    def _pickup_rules(cls, v):
        return check_preferred_pickup(v) if v is not None else v


def _entry_rows(db: Session, reference: str) -> list:
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


def _summary(rows: list, changed: list) -> dict:
    from services.donation_expiry import entry_status
    return {
        "batch_reference": rows[0].batch_reference,
        "status": entry_status(r.status for r in rows),
        "changed_items": len(changed),
        "items": [{"donation_id": r.donation_id, "status": r.status} for r in rows],
    }



def _phone_or_none(value: Optional[str]) -> Optional[str]:
    try:
        return normalize_ph_mobile(value or "")
    except ValueError:
        return None



@router.get("/expiry-rules")
def get_expiry_rules():
    """How long donors have to hand over a donation, in plain words, plus the
    one-tap cancel reasons. Public: the donate screen shows it before submit."""
    return {**expiry_rules(), "cancel_reasons": CANCEL_REASONS}


@router.post("/entries/{reference}/cancel")
def cancel_entry(
    reference: str,
    payload: CancelRequest,
    db: Session = Depends(get_db),
    current_user: Optional[User] = Depends(get_current_user_optional),
):
    """Withdraw a donation before it is handed over. Only items still
    Pending are cancelled; anything CSWS already received stays received."""
    rows = _entry_rows(db, reference)
    first = rows[0]
    staff = current_user is not None and has_role(current_user, *STAFF)
    owner = current_user is not None and first.user_id == current_user.user_id

    if not staff and not owner:
        if current_user is not None:
            raise HTTPException(status_code=403, detail="You can only cancel your own donations.")
        # A guest proves it is theirs with the phone number they gave
        # (F-17: one answer for every failure, and a limit on wrong tries).
        check_guest_cancel_attempts(first.batch_reference)
        guest = db.get(GuestDonor, first.guest_donor_id) if first.guest_donor_id else None
        given = _phone_or_none(payload.contact_number)
        if guest is None or given is None or given != _phone_or_none(guest.contact_number):
            record_guest_cancel_failure(first.batch_reference)
            raise HTTPException(status_code=403, detail=GUEST_CANCEL_FAILED)

    if not any(r.status == OPEN for r in rows):
        raise HTTPException(
            status_code=409,
            detail="Nothing to cancel: this donation was already received, expired or cancelled.",
        )

    reason = (payload.reason or "").strip() or (
        "Cancelled by CSWS for the donor." if staff and not owner else "Cancelled by the donor."
    )
    changed = close_rows(rows, "Cancelled", reason,
                         user_id=current_user.user_id if current_user else None)
    if current_user is not None:
        log_action(db, current_user, "CANCEL DONATION", "physical_donations", changed[0].donation_id,
                   old={"status": OPEN},
                   new={"status": "Cancelled", "batch_reference": first.batch_reference,
                        "items": [r.donation_id for r in changed], "reason": reason})
    if staff and first.user_id and not owner:
        notify_event(db, first.user_id, "donation_cancelled", "donation", changed[0].donation_id,
                     batch_no=first.batch_reference, reason=reason)
    if not staff:
        # CSWS stops waiting for it.
        notify_event_many(db, user_ids_with_role(db, ["CSWS Main Office"]), "donation_cancelled",
                          "donation", changed[0].donation_id,
                          batch_no=first.batch_reference, reason=reason)
    db.commit()
    return _summary(rows, changed)


@router.post("/entries/{reference}/reinstate")
def reinstate_entry(
    reference: str,
    payload: ReinstateRequest,
    db: Session = Depends(get_db),
    current_user: User = Depends(require_role(*STAFF)),
):
    """Reopen an Expired or Cancelled donation, e.g. the donor arrived late
    with the QR (UC-CM1 alt 2a). It goes back to Pending with a new deadline
    and can then be received as usual."""
    rows = _entry_rows(db, reference)
    # Items the donor removed stay removed.
    reopenable = [r for r in rows if not is_removed(r)]
    if not any(r.status in CLOSED for r in reopenable):
        raise HTTPException(status_code=409, detail="This donation is not expired or cancelled.")
    before = {r.donation_id: r.status for r in rows}
    changed = reopen_rows(reopenable, preferred_pickup_at=payload.preferred_pickup_at)
    first = rows[0]
    log_action(db, current_user, "REINSTATE DONATION", "physical_donations", changed[0].donation_id,
               old={"statuses": {str(r.donation_id): before[r.donation_id] for r in changed}},
               new={"status": OPEN, "batch_reference": first.batch_reference,
                    "expires_at": changed[0].expires_at.isoformat(), "note": payload.note})
    if first.user_id:
        notify_event(db, first.user_id, "donation_reinstated", "donation", changed[0].donation_id,
                     batch_no=first.batch_reference, date=nice_date(changed[0].expires_at))
    db.commit()
    out = _summary(rows, changed)
    out["expires_label"] = nice_date(changed[0].expires_at)
    return out


@router.post("/expiry/run")
def run_expiry(
    db: Session = Depends(get_db),
    x_cron_token: Optional[str] = Header(default=None),
    current_user: Optional[User] = Depends(get_current_user_optional),
):
    """Expire overdue donations and send due-soon reminders now. The screens
    already do this when they load; this is for a "Check now" button or a
    daily cron (send header X-Cron-Token = DONATION_CRON_TOKEN from .env)."""
    token = os.getenv("DONATION_CRON_TOKEN") or ""
    # F-17: constant-time comparison, on bytes so an unusual header can't error.
    by_cron = bool(token) and hmac.compare_digest((x_cron_token or "").encode(), token.encode())

    if not by_cron and not (current_user is not None and has_role(current_user, *STAFF)):
        raise HTTPException(status_code=403, detail="You do not have permission to access this resource")
    result = expire_overdue(db)
    db.commit()
    return result
