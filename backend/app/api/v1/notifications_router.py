from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy.orm import Session

from core.auth import get_current_user
from core.database import get_db
from models.notification import Notification
from schemas.notification import NotificationList

router = APIRouter(prefix="/notifications", tags=["notifications"])


def _unread(db: Session, user_id: int) -> int:
    return (
        db.query(Notification)
        .filter(Notification.user_id == user_id, Notification.is_read.is_(False))
        .count()
    )


@router.get("/", response_model=NotificationList)
def my_notifications(
    unread_only: bool = Query(default=False),
    limit: int = Query(default=50, ge=1, le=200),
    offset: int = Query(default=0, ge=0),
    db: Session = Depends(get_db),
    current_user=Depends(get_current_user),
):
    base = db.query(Notification).filter(Notification.user_id == current_user.user_id)
    q = base.filter(Notification.is_read.is_(False)) if unread_only else base
    items = (
        q.order_by(Notification.sent_at.desc(), Notification.notification_id.desc())
        .offset(offset)
        .limit(limit)
        .all()
    )
    return NotificationList(unread_count=_unread(db, current_user.user_id), items=items)


# POST (was GET): the Flutter app calls POST /notifications/{id}/read
@router.post("/{notification_id}/read")
def mark_read(
    notification_id: int,
    db: Session = Depends(get_db),
    current_user=Depends(get_current_user),
):
    n = db.get(Notification, notification_id)
    if not n or n.user_id != current_user.user_id:
        raise HTTPException(status_code=404, detail="Notification not found")
    n.is_read = True
    db.flush()
    return {"ok": True, "unread_count": _unread(db, current_user.user_id)}


@router.post("/read-all")
def mark_all_read(
    db: Session = Depends(get_db),
    current_user=Depends(get_current_user),
):
    db.query(Notification).filter(
        Notification.user_id == current_user.user_id,
        Notification.is_read.is_(False),
    ).update({"is_read": True}, synchronize_session=False)
    return {"ok": True, "unread_count": 0}