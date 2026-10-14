"""A file the app uploaded with POST /uploads, sent back in another request
(registration, internal accounts). See core/uploads.claim_upload."""
from typing import Optional

from pydantic import BaseModel, Field


class UploadRef(BaseModel):
    file_id: str = Field(..., min_length=36, max_length=36)
    # Only for uploads made before logging in (registration).
    claim_token: Optional[str] = Field(default=None, max_length=100)
