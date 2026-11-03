"""Live updates over WebSocket (GET /ws, api/v1/realtime_router.py).

When core.notifications.notify() adds a notification, it queues a push for
that user here. After the database commit succeeds, each queued user who has
the app open receives

    {"type": "notification", "event": ..., "entity_type": ..., "entity_id": ...,
     "unread_count": ...}

so the bell and the delivery / logistics screens update at once instead of
waiting for the next poll. A rollback drops the queued pushes.

LIMITATION: the registry of open connections lives in this process's memory.
That is right for the single Render instance NexaAid runs on. With several
server instances, a user connected to another instance would not get the
push (the app still polls every 30 s as a fallback); that would need a shared
channel such as Postgres LISTEN/NOTIFY.

Rule: a push is extra. Any failure here is logged and swallowed, so it can
never block or roll back the save that caused it.
"""
import asyncio
import logging
import threading
from typing import Optional

from sqlalchemy import event
from sqlalchemy.orm import Session

log = logging.getLogger("uvicorn.error")

_PENDING = "realtime_pending"     # Session.info key: [(user_id, payload), ...]
_COUNTS = "realtime_counts"       # Session.info key: {user_id: unread count}

# user_id -> {websocket: the event loop that serves it}
_connections: dict = {}
_lock = threading.Lock()


def register(user_id: int, websocket, loop: asyncio.AbstractEventLoop) -> None:
    with _lock:
        _connections.setdefault(user_id, {})[websocket] = loop


def unregister(user_id: int, websocket) -> None:
    with _lock:
        sockets = _connections.get(user_id)
        if sockets is not None:
            sockets.pop(websocket, None)
            if not sockets:
                _connections.pop(user_id, None)


def is_online(user_id: int) -> bool:
    with _lock:
        return bool(_connections.get(user_id))


def connection_count() -> int:
    with _lock:
        return sum(len(s) for s in _connections.values())


def queue_push(db: Session, user_id: int, event_name: str,
               entity_type: Optional[str], entity_id: Optional[int]) -> None:
    """Remember a push for after the commit. Nothing is kept for users who
    are not connected, so this costs nothing when nobody has the app open."""
    try:
        if user_id is None or not is_online(user_id):
            return
        db.info.setdefault(_PENDING, []).append((user_id, {
            "type": "notification", "event": event_name,
            "entity_type": entity_type, "entity_id": entity_id,
        }))
    except Exception:  # noqa: BLE001 - a push must never break a save
        log.exception("realtime: could not queue a push")


def unread_count(db: Session, user_id: int) -> int:
    from models.notification import Notification  # local import avoids a cycle
    return (db.query(Notification)
            .filter(Notification.user_id == user_id, Notification.is_read.is_(False))
            .count())


@event.listens_for(Session, "before_commit")
def _count_unread(session: Session) -> None:
    """Unread counts are read inside the transaction (no SQL is allowed after
    the commit). Only for users with a queued push."""
    pending = session.info.get(_PENDING)
    if not pending:
        return
    try:
        session.info[_COUNTS] = {uid: unread_count(session, uid) for uid in {u for u, _ in pending}}
    except Exception:  # noqa: BLE001
        log.exception("realtime: could not count unread notifications")
        session.info.pop(_COUNTS, None)


@event.listens_for(Session, "after_commit")
def _send_after_commit(session: Session) -> None:
    pending = session.info.pop(_PENDING, None)
    counts = session.info.pop(_COUNTS, None) or {}
    for user_id, payload in pending or ():
        try:
            send_to_user(user_id, {**payload, "unread_count": counts.get(user_id)})
        except Exception:  # noqa: BLE001 - the save is already committed
            log.exception("realtime: could not push to user %s", user_id)


@event.listens_for(Session, "after_rollback")
def _drop_after_rollback(session: Session) -> None:
    session.info.pop(_PENDING, None)
    session.info.pop(_COUNTS, None)


def send_to_user(user_id: int, message: dict) -> None:
    """Fire and forget to every open connection of this user, on the event
    loop that serves each one (callers may run in a worker thread)."""
    with _lock:
        targets = list(_connections.get(user_id, {}).items())
    for websocket, loop in targets:
        try:
            future = asyncio.run_coroutine_threadsafe(websocket.send_json(message), loop)
            future.add_done_callback(lambda f, uid=user_id, ws=websocket: _after_send(f, uid, ws))
        except Exception:  # noqa: BLE001 - e.g. the loop already closed
            log.warning("realtime: dropping a closed connection of user %s", user_id)
            unregister(user_id, websocket)


def _after_send(future, user_id: int, websocket) -> None:
    if future.cancelled() or future.exception() is not None:
        unregister(user_id, websocket)
