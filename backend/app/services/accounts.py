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

F-08 (security audit): the person's data is also removed where it was
copied, while every record and audit entry stays:
  - audit entries ABOUT the account (or its organization) keep their
    action, record, time and author, but personal values become "[deleted]";
    entries the account wrote lose their IP address and any home location;
    the DELETE ACCOUNT entry no longer copies the old name and email;
  - an organization whose only account this was keeps its name, type,
    status and history, but its contact person, contact email, address,
    registration number and legitimacy document are removed;
  - the donor's donations keep their items, quantities and statuses, but
    the home address, map pin, landmark and pickup notes are cleared.

Used by DELETE /admin/users/{id} and scripts/delete_accounts.py.
"""
import secrets
from datetime import datetime, timezone

from sqlalchemy import and_, or_

from core.audit import log_action
from core.auth import hash_password
from core.storage import get_storage
from models.audit_log_model import AuditLog
from models.organization_model import Organization
from models.physical_donation_model import PhysicalDonation
from models.upload_model import Upload, UploadBlob
from models.user_rbac_model import User

PERSONAL_UPLOADS = ("id_front", "id_back", "employee_id_card")
REDACTED = "[deleted]"
# F-08: personal values in audit entries about the deleted account or its organization.
PERSONAL_KEYS = frozenset({
    "email", "name", "first_name", "last_name", "username", "contact_number",
    "employee_id", "address", "deactivation_reason",
    "contact_person", "contact_email", "registration_no",
    "pickup_address", "pickup_lat", "pickup_lng", "pickup_landmark", "pickup_notes",
})
# ...and the donor's home location in entries the account wrote itself.
PICKUP_KEYS = frozenset({"pickup_address", "pickup_lat", "pickup_lng", "pickup_landmark", "pickup_notes"})


def deleted_email(user_id: int) -> str:
    return f"deleted-{user_id}@deleted.nexaaid.invalid"


def _anonymize_organization(db, user) -> bool:
    """The organization keeps its name, type, status and history. Its
    contact details go, unless another account still belongs to it."""
    if not user.organization_id:
        return False
    others = (db.query(User)
              .filter(User.organization_id == user.organization_id,
                      User.user_id != user.user_id, User.deleted_at.is_(None))
              .count())
    org = db.get(Organization, user.organization_id)
    if others or org is None:
        return False
    org.contact_person = "Deleted contact"
    org.contact_email = f"deleted-org-{org.organization_id}@deleted.nexaaid.invalid"
    org.address = None
    org.registration_no = None          # the organization may register again
    org.legitimacy_document_url = None
    return True


def _clear_pickup_details(db, user) -> int:
    """The donations stay (items, quantities, statuses, deliveries); the
    donor's home address and map pin do not."""
    return (db.query(PhysicalDonation)
            .filter(PhysicalDonation.user_id == user.user_id)
            .update({PhysicalDonation.pickup_address: None,
                     PhysicalDonation.pickup_lat: None,
                     PhysicalDonation.pickup_lng: None,
                     PhysicalDonation.pickup_landmark: None,
                     PhysicalDonation.pickup_notes: None},
                    synchronize_session=False))


def _redact(value, keys):
    if not isinstance(value, dict) or not keys & value.keys():
        return value
    return {k: (REDACTED if k in keys and v is not None else v) for k, v in value.items()}


def _redact_audit_logs(db, user, org_done: bool) -> int:
    """Every entry stays. Entries about the account (or its anonymized
    organization) lose the personal values; entries the account wrote lose
    their IP address and the donor's home location."""
    about = [and_(AuditLog.entity_type == "users", AuditLog.entity_id == user.user_id)]
    if org_done:
        about.append(and_(AuditLog.entity_type == "organizations",
                          AuditLog.entity_id == user.organization_id))
    changed = 0
    for log in db.query(AuditLog).filter(or_(AuditLog.user_id == user.user_id, *about)):
        is_about = (log.entity_type == "users" and log.entity_id == user.user_id) or (
            org_done and log.entity_type == "organizations" and log.entity_id == user.organization_id)
        keys = PERSONAL_KEYS if is_about else PICKUP_KEYS
        old_v, new_v = _redact(log.old_value, keys), _redact(log.new_value, keys)
        ip = None if log.user_id == user.user_id else log.ip_address
        if (old_v, new_v, ip) != (log.old_value, log.new_value, log.ip_address):
            log.old_value, log.new_value, log.ip_address = old_v, new_v, ip
            changed += 1
    return changed


def delete_account(db, user, by, request=None, source=None) -> None:
    """Anonymize `user`, log it under `by`. The caller checks the rules
    (admin only, not yourself, deactivated first). The caller commits."""
    old = {"role": user.role.role_name if user.role else None}   # F-08: no name or email copied
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

    org_done = _anonymize_organization(db, user)                      # F-08
    purposes = PERSONAL_UPLOADS + (("legitimacy_document",) if org_done else ())
    files = (db.query(Upload)
             .filter(Upload.owner_user_id == user.user_id, Upload.purpose.in_(purposes))
             .all())
    keys = [f.storage_key for f in files]
    if files:
        # The bytes in the database go too. Postgres would cascade this
        # (fk_upload_blobs_upload_id); doing it here works on every database.
        (db.query(UploadBlob).filter(UploadBlob.upload_id.in_([f.upload_id for f in files]))
         .delete(synchronize_session=False))
    for f in files:
        db.delete(f)

    cleared = _clear_pickup_details(db, user)                         # F-08
    redacted = _redact_audit_logs(db, user, org_done)                 # F-08

    new = {"deleted_files": len(keys), "cleared_pickups": cleared,
           "redacted_audit_entries": redacted, "organization_anonymized": org_done}
    if source:
        new["source"] = source
    log_action(db, by, "DELETE ACCOUNT", "users", user.user_id, old=old, new=new, request=request)
    db.flush()  # rows gone first; a file is never deleted while its row remains
    for key in keys:
        get_storage().delete(key)
