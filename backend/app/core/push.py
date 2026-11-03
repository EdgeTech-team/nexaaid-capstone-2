"""Push notifications to the Android app (Firebase Cloud Messaging, HTTP v1).

Manuscript Scope 2.4: registered users get a push when something happens
(e.g. their SMS report is validated). Every in-app notification
(core/notifications.notify) is also sent as a push, after the commit.

No schema change: there is no device_tokens table. Each user has one FCM
topic, "u_" + an HMAC of their user_id with SECRET_KEY, so nobody can guess
someone else's topic. The app asks GET /push/topic once signed in,
subscribes to it, and unsubscribes when the user signs out. The server
sends to that topic.

Credentials (never in the repo), the first one set wins:
  FIREBASE_CREDENTIALS_JSON  the service account JSON itself (Render)
  FIREBASE_CREDENTIALS_FILE  a path to it, e.g.
                             C:/nexaaid-secrets/firebase-service-account.json
Without either, pushes are off and nothing else changes.

Why no firebase-admin: one HTTPS call needs only an OAuth token signed with
the service account key, which PyJWT + cryptography (already installed) do;
firebase-admin would add gRPC and Google Cloud packages to the Render build.

Rule: a push is extra. It is sent in a worker thread after the commit, and
any failure is logged and swallowed, so it can never slow, block or roll
back the save that caused it.
"""
import hashlib
import hmac
import json
import logging
import os
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from typing import Optional

import httpx
import jwt
from sqlalchemy import event
from sqlalchemy.orm import Session

log = logging.getLogger("uvicorn.error")

_PENDING = "push_pending"     # Session.info key: [message, ...]
_SCOPE = "https://www.googleapis.com/auth/firebase.messaging"
_SEND_URL = "https://fcm.googleapis.com/v1/projects/{project}/messages:send"
_TIMEOUT = 10                 # seconds per HTTPS call

_lock = threading.Lock()
_creds: Optional[dict] = None
_creds_loaded = False
_token: Optional[str] = None
_token_expires = 0.0
_pool: Optional[ThreadPoolExecutor] = None


def _load_credentials() -> Optional[dict]:
    raw = os.getenv("FIREBASE_CREDENTIALS_JSON", "").strip()
    path = os.getenv("FIREBASE_CREDENTIALS_FILE", "").strip()
    if not raw and path:
        try:
            with open(path, encoding="utf-8") as f:
                raw = f.read()
        except OSError:
            log.warning("push: FIREBASE_CREDENTIALS_FILE %s could not be read; pushes are off", path)
            return None
    if not raw:
        return None
    try:
        info = json.loads(raw)
        if all(info.get(k) for k in ("project_id", "client_email", "private_key", "token_uri")):
            return info
    except (ValueError, AttributeError):
        pass
    log.warning("push: the Firebase service account is not valid JSON; pushes are off")
    return None


def credentials() -> Optional[dict]:
    """The service account, read once (None = pushes are off)."""
    global _creds, _creds_loaded
    with _lock:
        if not _creds_loaded:
            _creds = _load_credentials()
            _creds_loaded = True
        return _creds


def enabled() -> bool:
    return credentials() is not None


def topic_for(user_id: int) -> str:
    """The user's FCM topic. Topic names allow [a-zA-Z0-9-_.~%]."""
    from core.config import settings   # local import: tests set SECRET_KEY first
    digest = hmac.new(settings.SECRET_KEY.encode(), f"nexaaid-push:{user_id}".encode(),
                      hashlib.sha256).hexdigest()
    return f"u_{digest[:40]}"


def queue(db: Session, user_id: int, event_name: str, title: str, body: str,
          entity_type: Optional[str], entity_id: Optional[int],
          notification_id: Optional[int]) -> None:
    """Remember a push for after the commit. Nothing when pushes are off."""
    try:
        if user_id is None or not enabled():
            return
        db.info.setdefault(_PENDING, []).append({
            "topic": topic_for(user_id),
            "notification": {"title": title, "body": body},
            # The app opens what the notice is about (notifications_screen
            # openNotification). FCM data values must be strings.
            "data": {k: str(v) for k, v in {
                "event": event_name, "entity_type": entity_type,
                "entity_id": entity_id, "notification_id": notification_id,
            }.items() if v is not None},
            "android": {"priority": "high"},
        })
    except Exception:  # noqa: BLE001 - a push must never break a save
        log.exception("push: could not queue a push")


@event.listens_for(Session, "after_commit")
def _send_after_commit(session: Session) -> None:
    messages = session.info.pop(_PENDING, None)
    if not messages:
        return
    try:
        _submit(_send_all, messages)
    except Exception:  # noqa: BLE001 - the save is already committed
        log.exception("push: could not start sending")


@event.listens_for(Session, "after_rollback")
def _drop_after_rollback(session: Session) -> None:
    session.info.pop(_PENDING, None)


def _submit(fn, *args) -> None:
    """Run in a small worker pool, off the request. Tests replace this."""
    global _pool
    with _lock:
        if _pool is None:
            _pool = ThreadPoolExecutor(max_workers=2, thread_name_prefix="push")
    _pool.submit(fn, *args)


def _access_token(info: dict) -> str:
    """OAuth token for FCM from the service account (cached ~1 h)."""
    global _token, _token_expires
    with _lock:
        if _token and time.time() < _token_expires - 60:
            return _token
    now = int(time.time())
    assertion = jwt.encode(
        {"iss": info["client_email"], "scope": _SCOPE, "aud": info["token_uri"],
         "iat": now, "exp": now + 3600},
        info["private_key"], algorithm="RS256")
    r = httpx.post(info["token_uri"], timeout=_TIMEOUT, data={
        "grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer", "assertion": assertion})
    r.raise_for_status()
    body = r.json()
    with _lock:
        _token = body["access_token"]
        _token_expires = now + int(body.get("expires_in", 3600))
        return _token


def _forget_token() -> None:
    global _token
    with _lock:
        _token = None


def _send_all(messages: list) -> None:
    info = credentials()
    if info is None:
        return
    url = _SEND_URL.format(project=info["project_id"])
    for message in messages:
        try:
            r = httpx.post(url, timeout=_TIMEOUT, json={"message": message},
                           headers={"Authorization": f"Bearer {_access_token(info)}"})
            if r.status_code == 401:
                _forget_token()
            if r.status_code >= 300:
                log.warning("push: FCM answered %s for event %s", r.status_code,
                            message["data"].get("event"))
        except Exception:  # noqa: BLE001 - one failed push must not stop the rest
            log.exception("push: sending failed")
