"""GET /push/topic: the signed-in user's push topic (core/push.py). The
Android app subscribes to it after signing in and unsubscribes when the user
signs out. "enabled" is false while the server has no Firebase service
account; the app still subscribes, so pushes start once it is set."""
from fastapi import APIRouter, Depends

from core import push
from core.auth import get_current_user

router = APIRouter(prefix="/push", tags=["push"])


@router.get("/topic")
def my_push_topic(current_user=Depends(get_current_user)):
    return {"topic": push.topic_for(current_user.user_id), "enabled": push.enabled()}
