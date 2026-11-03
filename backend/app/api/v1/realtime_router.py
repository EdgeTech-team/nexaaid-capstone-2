"""GET /ws?token=<the login JWT>: live updates for the signed-in user
(core/realtime.py). Browsers cannot set an Authorization header on a
WebSocket, so the token comes as a query parameter; the access log never
shows query strings (F-22, core/log_privacy.py).

The server sends {"type": "hello", "unread_count": n} first, then one
{"type": "notification", ...} per new notification. The app sends "ping"
now and then (proxies close quiet connections) and gets "pong".
"""
import asyncio
import logging

from fastapi import APIRouter, HTTPException, WebSocket, WebSocketDisconnect

from core import database, realtime
from core.auth import get_current_user, get_current_user_allow_temporary_password

router = APIRouter(tags=["realtime"])
log = logging.getLogger("uvicorn.error")


def _sign_in(token: str):
    """(user_id, unread count), or (None, None) for a bad, expired or
    temporary-password token. Same checks as every HTTP endpoint (core/auth
    is used as is). The database session is closed right away, so an open
    socket never holds a connection."""
    db = database.SessionLocal()
    try:
        user = get_current_user(get_current_user_allow_temporary_password(token, db))
        return user.user_id, realtime.unread_count(db, user.user_id)
    except HTTPException:
        return None, None
    finally:
        db.close()


@router.websocket("/ws")
async def live_updates(websocket: WebSocket):
    user_id, unread = await asyncio.to_thread(_sign_in, websocket.query_params.get("token") or "")
    if user_id is None:
        await websocket.close(code=1008)   # policy violation: not signed in
        return
    await websocket.accept()
    realtime.register(user_id, websocket, asyncio.get_running_loop())
    try:
        await websocket.send_json({"type": "hello", "unread_count": unread})
        while True:
            if await websocket.receive_text() == "ping":
                await websocket.send_text("pong")
    except WebSocketDisconnect:
        pass
    except Exception:  # noqa: BLE001 - a broken socket only ends itself
        log.warning("realtime: connection of user %s ended with an error", user_id)
    finally:
        realtime.unregister(user_id, websocket)
