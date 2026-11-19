"""J2 / NF-015 (team agreement Nov 18, 2026, A2): proof of receipt.

The handover code
-----------------
When a delivery arrives (status Delivered) the server makes a random 6-digit
code. Only a keyed hash is stored (deliveries.handover_code_hash). The code
is shown once: to CSWS Main Office staff in the advance or stop-arrived
response, or through POST /deliveries/{id}/handover-code (CSWS Main Office,
or the DRRMO user who carried the goods). It never goes into a response to
the Barangay Receiving Representative or the Administrator, a
notification, the audit log or a log line. The representative types it
when confirming, which shows the goods were handed over in front of the
staff on site.

Hash: HMAC-SHA256 with key SECRET_KEY over "handover:{delivery_id}:{code}".
A plain SHA-256 of a 6-digit number is reversed by trying all 1,000,000
values; the HMAC cannot be without SECRET_KEY, which is not in the
database. The delivery id gives every delivery its own hash.

Deliveries at the same trip stop share one code and one lock.

The lock
--------
Every wrong code is an audit-log row (WRONG HANDOVER CODE) on a delivery.
Five in the last 15 minutes for the handover group (the delivery, or every
delivery of its trip stop) lock confirmation with 429 until the oldest of
those five is 15 minutes old; the fifth wrong try already gets 429. The row
is committed before the error is raised (get_db rolls back on errors). The
lock is checked before the code, for every account, on both the single and
the trip endpoint, and a new code does not reset it.
"""
import hashlib
import hmac
import secrets
from datetime import datetime, timedelta
from typing import List, Optional

from fastapi import HTTPException
from sqlalchemy import or_
from sqlalchemy.orm import Session

from core.audit import log_action
from core.config import settings
from core.uploads import LABEL, PURPOSES, sniff
from models.audit_log_model import AuditLog
from models.delivery import Delivery, Receipt
from models.logistics_request_model import LogisticsRequest
from models.upload_model import Upload, UploadBlob
from services.donation_expiry import now_utc, utc

MAX_WRONG_CODES = 5
LOCK_WINDOW = timedelta(minutes=15)
WRONG_CODE = "WRONG HANDOVER CODE"
CODE_ISSUED = "ISSUE HANDOVER CODE"


# ---------------------------------------------------------------------------
# Making and storing a code
# ---------------------------------------------------------------------------
def new_code() -> str:
    """A random 6-digit code, e.g. '048213' (leading zeros kept)."""
    return f"{secrets.randbelow(1_000_000):06d}"


def code_hash(delivery_id: int, code: str) -> str:
    message = f"handover:{delivery_id}:{code}".encode()
    return hmac.new(settings.SECRET_KEY.encode(), message, hashlib.sha256).hexdigest()


def stop_group(db: Session, delivery: Delivery) -> List[Delivery]:
    """The deliveries that share one handover code: the delivery itself, or
    every delivery of its trip stop that is waiting for the barangay."""
    if delivery.trip_id is None:
        return [delivery]
    return (db.query(Delivery)
            .filter(Delivery.trip_id == delivery.trip_id,
                    Delivery.destination_barangay_id == delivery.destination_barangay_id,
                    Delivery.status == "Delivered",
                    Delivery.deleted_at.is_(None))
            .order_by(Delivery.delivery_id).all())


def lock_group_ids(db: Session, delivery: Delivery) -> List[int]:
    """The deliveries whose wrong codes count together: the delivery, or
    every delivery of its trip stop (they share a code)."""
    if delivery.trip_id is None:
        return [delivery.delivery_id]
    return [i for (i,) in db.query(Delivery.delivery_id).filter(
        Delivery.trip_id == delivery.trip_id,
        Delivery.destination_barangay_id == delivery.destination_barangay_id)]


def issue(db: Session, deliveries: List[Delivery], user) -> str:
    """Give [deliveries] one new code (replacing any older one) and return
    it. The caller shows it once to the staff on site. The audit log says a
    code was made, never which. Does not commit."""
    code = new_code()
    now = now_utc()
    for d in deliveries:
        d.handover_code_hash = code_hash(d.delivery_id, code)
        d.handover_code_created_at = now
        log_action(db, user, CODE_ISSUED, "deliveries", d.delivery_id,
                   new={"issued_at": now.isoformat()})
    db.flush()
    return code


def carried_by(db: Session, delivery: Delivery, user) -> bool:
    """Is [user] the DRRMO user who accepted (and carried) this delivery?"""
    req = (db.query(LogisticsRequest)
           .filter(LogisticsRequest.delivery_id == delivery.delivery_id,
                   LogisticsRequest.status.in_(("Accepted", "Completed")))
           .order_by(LogisticsRequest.request_id.desc()).first())
    return req is not None and req.assigned_to_user_id == user.user_id


# ---------------------------------------------------------------------------
# Checking a code, with the lock
# ---------------------------------------------------------------------------
def _recent_wrong(db: Session, ids: List[int]) -> List[datetime]:
    """When the last few wrong codes for these deliveries were entered,
    only those in the last 15 minutes."""
    since = now_utc() - LOCK_WINDOW
    rows = (db.query(AuditLog.timestamp)
            .filter(AuditLog.entity_type == "deliveries",
                    AuditLog.entity_id.in_(ids),
                    AuditLog.action == WRONG_CODE)
            .order_by(AuditLog.log_id.desc())
            .limit(MAX_WRONG_CODES).all())
    return [utc(t) for (t,) in rows if utc(t) > since]


def _locked_until(times: List[datetime]) -> Optional[datetime]:
    if len(times) >= MAX_WRONG_CODES:
        return min(times) + LOCK_WINDOW
    return None


def _too_many(until: datetime) -> HTTPException:
    wait = max(1, int((until - now_utc()).total_seconds()) + 1)
    return HTTPException(
        status_code=429,
        detail=(f"Too many wrong handover codes. Confirmation is locked; try again in "
                f"{(wait + 59) // 60} minute(s)."),
        headers={"Retry-After": str(wait)},
    )


def check_code(db: Session, deliveries: List[Delivery], code: str, user) -> None:
    """The handover code for [deliveries] (one delivery, or every delivery of
    a trip stop, which share one code). Raises 429 while locked, 409 when no
    code was made yet, 403 when the code is wrong (429 on the fifth wrong
    try). A wrong try is committed as an audit row before the error."""
    ids = lock_group_ids(db, deliveries[0])
    until = _locked_until(_recent_wrong(db, ids))
    if until is not None:
        raise _too_many(until)
    if any(d.handover_code_hash is None for d in deliveries):
        raise HTTPException(
            status_code=409,
            detail=("There is no handover code for this delivery yet. Ask the CSWS staff "
                    "(or the DRRMO driver) at the handover to show one."),
        )
    if all(hmac.compare_digest(d.handover_code_hash, code_hash(d.delivery_id, code))
           for d in deliveries):
        return
    log_action(db, user, WRONG_CODE, "deliveries", deliveries[0].delivery_id,
               new={"result": "wrong handover code"})
    db.commit()   # kept even though the request fails
    times = _recent_wrong(db, ids)
    until = _locked_until(times)
    if until is not None:
        raise _too_many(until)
    left = MAX_WRONG_CODES - len(times)
    raise HTTPException(
        status_code=403,
        detail=(f"The handover code is not correct. After {left} more wrong "
                f"{'try' if left == 1 else 'tries'}, confirmation is locked for 15 minutes."),
    )


# ---------------------------------------------------------------------------
# The signature and the optional slip photo
# ---------------------------------------------------------------------------
def _own_file(db: Session, file_id: str, purpose: str, user, what: str, again: str) -> Upload:
    """A file the confirming user uploaded for [purpose], whose first bytes
    are an accepted image type, not used by any earlier receipt."""
    up = db.query(Upload).filter(Upload.file_id == file_id).first()
    if up is None or up.purpose != purpose or up.owner_user_id != user.user_id:
        raise HTTPException(status_code=422, detail=f"The {what} was not found. Please {again}.")
    blob = db.get(UploadBlob, up.upload_id)
    allowed = PURPOSES[purpose].types
    if blob is None or sniff(blob.data) not in allowed:
        kinds = " or ".join(sorted(LABEL[t] for t in allowed))
        raise HTTPException(status_code=422, detail=f"The {what} must be a {kinds} image. Please {again}.")
    used = (db.query(Receipt.receipt_id)
            .filter(or_(Receipt.signature_file_id == file_id,
                        Receipt.slip_photo_file_id == file_id))
            .first())
    if used is not None:
        raise HTTPException(
            status_code=422,
            detail=f"This {what} was already used for an earlier receipt. Please {again}.",
        )
    return up


def check_proof_files(db: Session, proof, user) -> None:
    """J2 / NF-015: the signature (required) and slip photo (optional) of
    [proof] (a ReceiptProof). Checked once per request, so the deliveries of
    one trip stop confirmed together share them. Raises 422."""
    _own_file(db, proof.signature_file_id, "receipt_signature", user,
              "signature", "sign again")
    if proof.slip_photo_file_id:
        _own_file(db, proof.slip_photo_file_id, "receipt_slip_photo", user,
                  "slip photo", "take the photo again")
