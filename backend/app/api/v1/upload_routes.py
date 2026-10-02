"""
api/v1/upload_routes.py — Sprint 0 foundation: upload service (Castillo).
 
POST /uploads            multipart: purpose + file  ->  {file_id, url, ...}
GET  /uploads/{file_id}  the file itself (private files: owner or Administrator only)
 
Agreed response shape for the team: {file_id, url}. Anonymous uploads
(registration) also get a one-time claim_token — see core/uploads.claim_upload.
"""
import hashlib
import secrets
import uuid
from typing import Optional

from fastapi import APIRouter, Depends, File, Form, HTTPException, UploadFile, status
from fastapi.responses import FileResponse
from sqlalchemy.orm import Session

from core.auth import get_current_user_optional, has_role
from core.database import get_db
from core.storage import get_storage
from core.uploads import ( EXTENSION, LABEL, MAX_BYTES, PDF, PURPOSES, clean_image, file_url, hash_token, read_limited, sniff, )

from models.upload_model import Upload
from models.user_rbac_model import User

router = APIRouter(prefix="/uploads", tags=["uploads"])

@router.post("", status_code=status.HTTP_201_CREATED)
def upload_file(
    purpose:str = Form(...),
    file: UploadFile = File(...),
    db: Session = Depends(get_db),
    user: Optional[User] = Depends(get_current_user_optional),
):
    rule = PURPOSES.get(purpose)
    if rule is None:
        raise HTTPException(
            status.HTTP_400_BAD_REQUEST, 
            f"purpose must be one of: {',' .join(sorted(PURPOSES))}",
           )
    if user is not None and not user.is_active:
        raise HTTPException(status.HTTP_403_FORBIDDEN, "Account is deactivated")
    if rule.roles is not None:
        if user is None:
            raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Log in to upload this file.")
        if not has_role(user, *rule.roles):
            raise HTTPException(status.HTTP_403_FORBIDDEN, "You do not have permission to upload this file.")

    data = read_limited(file.file)
    content_type = sniff(data)
    if content_type not in rule.types:
        allowed = ", ".join(sorted(LABEL[t] for t in rule.types))
        raise HTTPException(
            status.HTTP_415_UNSUPPORTED_MEDIA_TYPE,
            f"Only {allowed} files are accepted.", 
        )
    if content_type != PDF:
        data = clean_image(data, content_type)
        if len(data) > MAX_BYTES:
            raise HTTPException(
                413,
                f"The image is too large",
            )
    
    file_id = str(uuid.uuid4())
    storage_key = f"{rule.visibility}/{file_id}.{EXTENSION[content_type]}"
    claim_token = None if user is not None else secrets.token_urlsafe(32)
    
      
    storage = get_storage()
    storage.save(storage_key, data)
    try:
        db.add(Upload(
            file_id=file_id,
            purpose=purpose,
            visibility=rule.visibility,
            content_type=content_type,
            size_bytes=len(data),
            sha256=hashlib.sha256(data).hexdigest(),
            storage_key=storage_key,
            owner_user_id=user.user_id if user is not None else None,
            claim_token_hash=hash_token(claim_token) if claim_token else None,
        ))
        db.flush()  # commit happens in get_db
    except Exception:
        storage.delete(storage_key)  # don't leave an orphan file behind
        raise
 
    return {
        "file_id": file_id,
        "url": file_url(file_id),
        "purpose": purpose,
        "visibility": rule.visibility,
        "content_type": content_type,
        "size_bytes": len(data),
        # Only for uploads made without logging in (registration).
        # Send it back with the register request. Shown once, never stored raw.
        "claim_token": claim_token,
    }
 
 
@router.get("/{file_id}")
def get_file(
    file_id: str,
    db: Session = Depends(get_db),
    user: Optional[User] = Depends(get_current_user_optional),
):
    # 404 (not 403) for files you may not see, so nobody can probe
    # which file_ids exist.
    missing = HTTPException(status.HTTP_404_NOT_FOUND, "File not found")
    up = db.query(Upload).filter(Upload.file_id == file_id).first()
    if up is None:
        raise missing
 
    private = up.visibility == "private"
    if private:
        allowed = (
            user is not None
            and user.is_active
            and (up.owner_user_id == user.user_id or has_role(user, "Administrator"))
        )
        if not allowed:
            raise missing
 
    path = get_storage().path(up.storage_key)
    if not path.exists():
        raise missing
 
    disposition = "attachment" if up.content_type == PDF else "inline"
    return FileResponse(
        path,
        media_type=up.content_type,
        headers={
            "Content-Disposition": f'{disposition}; filename="{up.file_id}.{EXTENSION[up.content_type]}"',
            "X-Content-Type-Options": "nosniff",
            "Content-Security-Policy": "default-src 'none'; sandbox",
            "Cache-Control": "private, no-store" if private else "public, max-age=86400",
        },
    )