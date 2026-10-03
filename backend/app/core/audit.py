"""Write rows to audit_logs (manuscript UC-A4 / Table 38: system activity
logs, read-only, for the Administrator)."""
from typing import Optional

from fastapi import Request
from sqlalchemy.orm import Session

from models.audit_log_model import AuditLog


def log_action(
    db: Session,
    user,
    action: str,
    entity_type: str,
    entity_id: Optional[int] = None,
    old: Optional[dict] = None,
    new: Optional[dict] = None,
    request: Optional[Request] = None,
) -> None:
    db.add(AuditLog(
        user_id=user.user_id,
        action=action,
        entity_type=entity_type,
        entity_id=entity_id,
        old_value=old,
        new_value=new,
        ip_address=request.client.host if request is not None and request.client else None,
    ))
