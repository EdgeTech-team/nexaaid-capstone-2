"""
api/v1/donation_info_routes.py — barangay donation-sending info (adviser item 7).

DISPLAY ONLY (manuscript Scope Limitation #5): NexaAid never processes,
holds or verifies money. Donors send it straight to the barangay.

A barangay can publish several payment methods (J3), each with its own QR.

GET    /barangays/{id}/donation-info                  public: all of the barangay's methods
POST   /barangays/{id}/donation-info/methods          Barangay Receiving Representative (own barangay
PUT    /barangays/{id}/donation-info/methods/{mid}    only, like UC-B1 alt 3a) or Administrator
DELETE /barangays/{id}/donation-info/methods/{mid}
GET    /reports/{id}/donation-info                    public for validated reports (UC-D2, guests too)
PUT    /reports/{id}/donation-info                    CSWS Disaster Unit or Administrator: override
DELETE /reports/{id}/donation-info                    for this report only (UC-CD1)
"""
from typing import List, Optional

from fastapi import APIRouter, Depends, HTTPException, Request, status
from sqlalchemy.orm import Session

from core.audit import log_action
from core.auth import barangay_scope, get_current_user_optional, has_role, require_role
from core.database import get_db
from core.uploads import file_url
from models.barangay_model import Barangay
from models.donation_info_model import BarangayDonationMethod, ReportDonationInfo
from models.report import DisasterReport
from models.upload_model import Upload
from models.user_rbac_model import User
from schemas.donation_info_schema import NOTE, DonationInfoIn

router = APIRouter(tags=["donation info"])

FIELDS = ("provider", "account_name", "account_number", "instructions", "qr_file_id")
REP_OR_ADMIN = ("Barangay Receiving Representative", "Administrator")
UNIT_OR_ADMIN = ("CSWS Disaster Unit", "Administrator")


def info_dict(row) -> Optional[dict]:
    if row is None:
        return None
    return {
        # Only barangay methods have a method_id; a report override does not.
        "method_id": getattr(row, "method_id", None),
        **{k: getattr(row, k) for k in FIELDS},
        "qr_url": file_url(row.qr_file_id) if row.qr_file_id else None,
        "updated_at": row.updated_at,
    }


def _barangay(db: Session, barangay_id: int) -> Barangay:
    b = db.get(Barangay, barangay_id)
    if b is None:
        raise HTTPException(status_code=404, detail="Barangay not found")
    return b


def _methods(db: Session, barangay_id: int) -> List[BarangayDonationMethod]:
    """A barangay's methods, oldest first (stable display order)."""
    return (
        db.query(BarangayDonationMethod)
        .filter(BarangayDonationMethod.barangay_id == barangay_id)
        .order_by(BarangayDonationMethod.method_id)
        .all()
    )


def _method(db: Session, barangay_id: int, method_id: int) -> BarangayDonationMethod:
    m = db.get(BarangayDonationMethod, method_id)
    if m is None or m.barangay_id != barangay_id:
        raise HTTPException(status_code=404, detail="Donation method not found")
    return m


def _check_qr(db: Session, qr_file_id: Optional[str], user: User, already_ok: set) -> None:
    """The QR must be a barangay_donation_qr upload made by this user. The
    Administrator may use any; a QR already on the record (or the barangay's
    methods, for an override) may be kept."""
    if qr_file_id is None or qr_file_id in already_ok:
        return
    up = db.query(Upload).filter(Upload.file_id == qr_file_id).first()
    if (up is None or up.purpose != "barangay_donation_qr"
            or (up.owner_user_id != user.user_id and not has_role(user, "Administrator"))):
        raise HTTPException(status_code=400,
                            detail="The QR image was not found. Please upload it again.")


def _save(db: Session, row, payload: DonationInfoIn, user: User, entity: str,
          entity_id: Optional[int], request: Request, old: Optional[dict] = None):
    """Apply the payload, flush, then audit. The flush comes first so a new
    method has its method_id for the audit entry."""
    for k in FIELDS:
        setattr(row, k, getattr(payload, k))
    row.updated_by_user_id = user.user_id
    db.flush()
    db.refresh(row)
    eid = entity_id if entity_id is not None else getattr(row, "method_id", None)
    log_action(db, user, "UPDATE DONATION INFO", entity, eid,
               old=old, new={k: getattr(payload, k) for k in FIELDS}, request=request)
    return row


# ---------------------------------------------------------------- barangay

def _barangay_payload(db: Session, b: Barangay) -> dict:
    methods = _methods(db, b.barangay_id)
    return {
        "barangay_id": b.barangay_id,
        "barangay_name": b.barangay_name,
        "methods": [info_dict(m) for m in methods],
        # Kept for older clients: the first method, as the single "info" used to be.
        "info": info_dict(methods[0]) if methods else None,
        "note": NOTE,
    }


@router.get("/barangays/{barangay_id}/donation-info")
def get_barangay_info(barangay_id: int, db: Session = Depends(get_db)):
    return _barangay_payload(db, _barangay(db, barangay_id))


def _rep_may_edit(user: User, barangay_id: int) -> None:
    own = barangay_scope(user)          # None for the Administrator
    if own is not None and own != barangay_id:
        raise HTTPException(status_code=403,
                            detail="You can only edit the donation info of your assigned barangay.")


@router.post("/barangays/{barangay_id}/donation-info/methods",
             status_code=status.HTTP_201_CREATED)
def add_barangay_method(
    barangay_id: int,
    payload: DonationInfoIn,
    request: Request,
    db: Session = Depends(get_db),
    user: User = Depends(require_role(*REP_OR_ADMIN)),
):
    _rep_may_edit(user, barangay_id)
    _barangay(db, barangay_id)
    _check_qr(db, payload.qr_file_id, user, set())
    row = BarangayDonationMethod(barangay_id=barangay_id)
    db.add(row)
    # The row is empty until _save fills it, so _save must not flush first
    # (the "has info" check would reject it): it sets the fields, then flushes.
    _save(db, row, payload, user, "barangay_donation_method", None, request)
    return info_dict(row)


@router.put("/barangays/{barangay_id}/donation-info/methods/{method_id}")
def put_barangay_method(
    barangay_id: int,
    method_id: int,
    payload: DonationInfoIn,
    request: Request,
    db: Session = Depends(get_db),
    user: User = Depends(require_role(*REP_OR_ADMIN)),
):
    _rep_may_edit(user, barangay_id)
    _barangay(db, barangay_id)
    row = _method(db, barangay_id, method_id)
    _check_qr(db, payload.qr_file_id, user, {row.qr_file_id})
    old = {k: getattr(row, k) for k in FIELDS}
    _save(db, row, payload, user, "barangay_donation_method", method_id, request, old=old)
    return info_dict(row)


@router.delete("/barangays/{barangay_id}/donation-info/methods/{method_id}",
               status_code=status.HTTP_204_NO_CONTENT)
def delete_barangay_method(
    barangay_id: int,
    method_id: int,
    request: Request,
    db: Session = Depends(get_db),
    user: User = Depends(require_role(*REP_OR_ADMIN)),
):
    _rep_may_edit(user, barangay_id)
    _barangay(db, barangay_id)
    row = _method(db, barangay_id, method_id)
    log_action(db, user, "REMOVE DONATION INFO", "barangay_donation_method", method_id,
               old={k: getattr(row, k) for k in FIELDS}, request=request)
    db.delete(row)
    return None


# ------------------------------------------------------------------ report

def _report(db: Session, report_id: int) -> DisasterReport:
    r = db.get(DisasterReport, report_id)
    if r is None:
        raise HTTPException(status_code=404, detail="Report not found")
    return r


@router.get("/reports/{report_id}/donation-info")
def get_report_info(
    report_id: int,
    db: Session = Depends(get_db),
    user: Optional[User] = Depends(get_current_user_optional),
):
    """UC-D2: shown with the report, to guests too. The report's override
    if the Disaster Unit set one, else all of the barangay's methods."""
    r = _report(db, report_id)
    staff = user is not None and user.is_active and has_role(
        user, "csws_staff", "admin", "barangay_official")
    if r.status != "Validated" and not staff:
        raise HTTPException(status_code=404, detail="Report not found")
    override = db.get(ReportDonationInfo, report_id)
    methods = [] if override else _methods(db, r.barangay_id)
    b = db.get(Barangay, r.barangay_id)
    return {
        "report_id": r.report_id,
        "barangay_id": r.barangay_id,
        "barangay_name": b.barangay_name if b else None,
        "source": "report" if override else ("barangay" if methods else None),
        "methods": [info_dict(m) for m in methods],
        # Kept for older clients: the override, else the first method.
        "info": info_dict(override or (methods[0] if methods else None)),
        "note": NOTE,
    }


@router.put("/reports/{report_id}/donation-info")
def put_report_info(
    report_id: int,
    payload: DonationInfoIn,
    request: Request,
    db: Session = Depends(get_db),
    user: User = Depends(require_role(*UNIT_OR_ADMIN)),
):
    r = _report(db, report_id)
    row = db.get(ReportDonationInfo, report_id)
    keep = {m.qr_file_id for m in _methods(db, r.barangay_id)}
    if row is not None:
        keep.add(row.qr_file_id)
    _check_qr(db, payload.qr_file_id, user, keep)
    old = {k: getattr(row, k) for k in FIELDS} if row is not None else None
    if row is None:
        row = ReportDonationInfo(report_id=report_id)
        db.add(row)
    _save(db, row, payload, user, "report_donation_info", report_id, request, old=old)
    return get_report_info(report_id, db, user)


@router.delete("/reports/{report_id}/donation-info", status_code=status.HTTP_204_NO_CONTENT)
def delete_report_info(
    report_id: int,
    request: Request,
    db: Session = Depends(get_db),
    user: User = Depends(require_role(*UNIT_OR_ADMIN)),
):
    """Remove the override; the report shows the barangay's methods again."""
    _report(db, report_id)
    row = db.get(ReportDonationInfo, report_id)
    if row is not None:
        log_action(db, user, "REMOVE DONATION INFO", "report_donation_info", report_id,
                   old={k: getattr(row, k) for k in FIELDS}, request=request)
        db.delete(row)
    return None