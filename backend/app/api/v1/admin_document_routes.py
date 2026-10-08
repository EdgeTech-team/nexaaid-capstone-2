"""
api/v1/admin_document_routes.py — what the Administrator needs to review
an account or an organization (adviser items 2 and 2.1).

GET /admin/users/{user_id}                       account detail (UC-A1)
GET /admin/users/{user_id}/documents             files that account owns (UC-D1 ID front/back)
GET /admin/organizations/{organization_id}/document
                                                 the supporting document (UC-A2 step 4, alt 4a)

These only list files. The bytes of a private file are still served only
by GET /uploads/{file_id}, which repeats the owner/Administrator check
(RA 10173: ID photos and documents are sensitive personal information).
"""
import re
from typing import Optional

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session

from core.auth import require_role
from core.database import get_db
from core.storage import get_storage
from core.uploads import file_url
from models.barangay_model import Barangay
from models.organization_model import Organization
from models.upload_model import Upload
from models.user_rbac_model import User

router = APIRouter(prefix="/admin", tags=["admin"])

ADMIN = "Administrator"
_UPLOAD_URL = re.compile(r"^/uploads/([0-9a-f\-]{36})$")


def _doc(up: Upload) -> dict:
    return {
        "file_id": up.file_id,
        "purpose": up.purpose,
        "url": file_url(up.file_id),
        "content_type": up.content_type,
        "created_at": up.created_at,
    }


def _get_user(db: Session, user_id: int) -> User:
    user = db.get(User, user_id)
    if user is None:
        raise HTTPException(status_code=404, detail="Account not found")  # UC-A1 alt 3a
    return user


@router.get("/users/{user_id}")
def get_user_detail(
    user_id: int,
    db: Session = Depends(get_db),
    current_user: User = Depends(require_role(ADMIN)),
):
    u = _get_user(db, user_id)
    org = db.get(Organization, u.organization_id) if u.organization_id else None
    brgy = db.get(Barangay, u.assigned_barangay_id) if u.assigned_barangay_id else None
    return {
        "user_id": u.user_id,
        "first_name": u.first_name,
        "last_name": u.last_name,
        "email": u.email,
        "contact_number": u.contact_number,
        "role": u.role.role_name if u.role else None,
        "is_active": u.is_active,
        "deactivation_reason": u.deactivation_reason,
        "deactivated_at": u.deactivated_at,
        "created_at": u.created_at,
        "id_type": u.id_type,
        "employee_id": u.employee_id,
        "organization_id": u.organization_id,
        "organization": org.org_name if org else None,
        "organization_status": org.status if org else None,
        "assigned_barangay_id": u.assigned_barangay_id,
        "assigned_barangay": brgy.barangay_name if brgy else None,
    }


@router.get("/users/{user_id}/documents")
def list_user_documents(
    user_id: int,
    db: Session = Depends(get_db),
    current_user: User = Depends(require_role(ADMIN)),
):
    _get_user(db, user_id)
    rows = (
        db.query(Upload)
        .filter(Upload.owner_user_id == user_id)
        .order_by(Upload.created_at.desc(), Upload.upload_id.desc())
        .all()
    )
    return [_doc(up) for up in rows]


def document_status(db: Session, url: Optional[str]) -> dict:
    """UC-A2 alt 4a. 'missing': no document at all. 'unreadable': it points
    at an upload whose row or file is gone. 'external': an old link typed
    in before uploads existed (cannot be checked). 'ok': ready to view."""
    url = (url or "").strip()
    if not url:
        return {"status": "missing", "url": None, "content_type": None}
    m = _UPLOAD_URL.match(url)
    if m is None:
        return {"status": "external", "url": url, "content_type": None}
    up = db.query(Upload).filter(Upload.file_id == m.group(1)).first()
    if up is None or not get_storage().path(up.storage_key).exists():
        return {"status": "unreadable", "url": url, "content_type": None}
    return {"status": "ok", **_doc(up)}


@router.get("/organizations/{organization_id}/document")
def get_organization_document(
    organization_id: int,
    db: Session = Depends(get_db),
    current_user: User = Depends(require_role(ADMIN)),
):
    org = db.get(Organization, organization_id)
    if org is None:
        raise HTTPException(status_code=404, detail="Organization not found")
    return document_status(db, org.legitimacy_document_url)
