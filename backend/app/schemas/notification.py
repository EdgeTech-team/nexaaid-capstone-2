from datetime import datetime
from typing import List, Optional

from pydantic import BaseModel, ConfigDict


class NotificationResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    notification_id: int
    type: str
    title: str
    message: str
    entity_type: Optional[str] = None
    entity_id: Optional[int] = None
    is_read: bool
    sent_at: datetime


class NotificationList(BaseModel):
    unread_count: int
    items: List[NotificationResponse]