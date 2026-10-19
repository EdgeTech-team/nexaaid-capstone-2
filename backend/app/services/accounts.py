"""Deleting an account (Appendix H 1.2, testing feedback Oct 2026).

A user row cannot really be deleted once it has reports, deliveries,
receipts or logistics requests: those foreign keys are RESTRICT, and the
records must stay for transparency. That is also why deleting "sample data"
in Neon left the users behind and registration kept saying "Email already
registered".

So an account is anonymized instead:
  - name, email, username, phone, address, employee ID and barangay are
    cleared, so the email, username and employee ID can be used again;
  - ID photos and the employee ID card are deleted (RA 10173: no personal
    data longer than needed);
  - the password is replaced, is_active is false and deleted_at is set, so
    the account can never log in and disappears from every admin list.
Records the account made keep pointing at the row and show "Deleted User".

Used by DELETE /admin/users/{id} and scripts/delete_accounts.py.
"""
import secrets
from datetime import datetime, timezone

from core.audit import log_action
from core.auth import hash_password
from core.storage import get_storage
from models.upload_model import Upload, UploadBlob

PERSONAL_UPLOADS = ("id_front", "id_back", "employee_id_card")


def deleted_email(user_id: int) -> str:
    return f"deleted-{user_id}@deleted.nexaaid.invalid"


def delete_account(db, user, by, request=None, source=None) -> None:
    """Anonymize `user`, log it under `by`. The caller checks the rules
    (admin only, not yourself, deactivated first). The caller commits."""
    old = {"name": f"{user.first_name} {user.last_name}".strip(), "email": user.email,
           "username": user.username, "employee_id": user.employee_id,
           "role": user.role.role_name if user.role else None}
    now = datetime.now(timezone.utc)
    user.first_name = "Deleted"
    user.last_name = "User"
    user.email = deleted_email(user.user_id)
    user.username = None
    user.contact_number = "N/A"
    user.address = None
    user.employee_id = None
    user.id_document_url = None
    user.id_type = None
    user.assigned_barangay_id = None
    user.password_hash = hash_password(secrets.token_urlsafe(32))  # nobody knows it
    user.must_change_password = False
    user.is_active = False
    user.deactivated_at = user.deactivated_at or now
    user.deleted_at = now

    files = (db.query(Upload)
             .filter(Upload.owner_user_id == user.user_id, Upload.purpose.in_(PERSONAL_UPLOADS))
             .all())
    keys = [f.storage_key for f in files]
    if files:
        # The bytes in the database go too. Postgres would cascade this
        # (fk_upload_blobs_upload_id); doing it here works on every database.
        (db.query(UploadBlob).filter(UploadBlob.upload_id.in_([f.upload_id for f in files]))
         .delete(synchronize_session=False))
    for f in files:
        db.delete(f)

    new = {"deleted_files": len(keys)}
    if source:
        new["source"] = source
    log_action(db, by, "DELETE ACCOUNT", "users", user.user_id, old=old, new=new, request=request)
    db.flush()  # rows gone first; a file is never deleted while its row remains
    for key in keys:
        get_storage().delete(key)
