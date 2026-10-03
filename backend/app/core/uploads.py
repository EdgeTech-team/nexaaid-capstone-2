"""
core/uploads.py — rules for what can be uploaded, by whom, and how
registration attaches a file to a new account.
 
Used by:
  - api/v1/upload_routes.py   (POST/GET /uploads)
  - Hoyohoy, registration (adviser items 2 and 2.1): claim_upload()
  - Mariquit, barangay donation QR (adviser item 7): purpose "barangay_donation_qr"
"""

import hashlib
import io
import secrets
from dataclasses import dataclass
from datetime import datetime,timedelta, timezone
from typing import Iterable, Optional, Tuple

from fastapi import HTTPException, status
from PIL import Image, ImageOps, UnidentifiedImageError
from sqlalchemy.orm import Session

from core.config import settings
from core.storage import get_storage
from models.upload_model import Upload

MAX_BYTES = settings.MAX_UPLOAD_MB * 1024 * 1024
UNCLAIMED_TTL = timedelta(hours=24) #ownerless registration uploads are purged after this

JPEG, PNG, PDF = "image/jpeg", "image/png", "application/pdf"
EXTENSION = {JPEG: "jpg", PNG: "png", PDF: "pdf"}
LABEL = {JPEG: "JPG", PNG: "PNG", PDF: "PDF"}

#Refuse "decompression bombs": tiny files that expand to huge images. 
Image.MAX_IMAGE_PIXELS = 40_000_000  # 40 megapixels, about 8k x 5k. The default is 89 million, which is too high.


@dataclass(frozen=True)
class Purpose:
    visibility: str             #private | public
    types: frozenset
    roles: Optional[Tuple[str, ...]]    #None = anyone, even before logging in.
    
DOCS = frozenset({JPEG, PNG, PDF})
IMAGES = frozenset({JPEG, PNG})

PURPOSES = {
    #UC-D1 step 3 / alt 6a: donor's valid ID, front and back. 
    "id_front": Purpose("private", DOCS, None),
    "id_back": Purpose("private", DOCS, None),
    #UC-R1 / UC-A2 alt 4a: organization legitimacy documents 
    "legitimacy_document": Purpose ("private", DOCS, None),
    #Barangay Ewallet QR shown to donors. DISPLAY ONLY;
    #NexaAid never processes money (manucsript limitation)
    "barangay_donation_qr": Purpose(
        "public", IMAGES,
        ("Barangay Receiving Representative", "CSWS Disaster Unit", "Administrator"),    
        ),
}

    
def file_url(file_id:str) -> str:
    return f"/uploads/{file_id}"

def hash_token(token:str) -> str:
    return hashlib.sha256(token.encode()).hexdigest()



def read_limited(fileobj) -> bytes: 
    data = fileobj.read(MAX_BYTES + 1)
    if not data:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "The file is empty")
    if len(data) > MAX_BYTES:
        raise HTTPException(
            413,
            f"The file is larger than {settings.MAX_UPLOAD_MB} MB.",
        )
    return data


def sniff(data: bytes) -> Optional[str]:
    #Decide the type from the file's first bytes. The filename and the client's Content-Type header are ignored, since both can be faked.
    if data.startswith(b"\xFF\xD8\xFF"):
        return JPEG
    if data.startswith(b"\x89PNG\r\n\x1A\n"):
        return PNG
    if data.startswith(b"%PDF-"):
        return PDF
    return None


def clean_image(data: bytes, content_type: str) -> bytes:
    """Re-encode the image. This drops EXIF metadata (phone photos of IDs
    often carry the GPS location of the donor's home) and anything hidden
    after the image data."""
    try:
        with Image.open(io.BytesIO(data)) as original:
            original.load()  #load the image data to catch errors early
            img = ImageOps.exif_transpose(original)
            out = io.BytesIO()
            if content_type == JPEG:
                img.convert("RGB").save(out,"JPEG", quality=88, optimize=True)
            else: 
                img.save(out, "PNG", optimize=True)
            return out.getvalue()
    except (UnidentifiedImageError, Image.DecompressionBombError, OSError, ValueError):
        # UC-D1 alt 6a: "If the ID is invalid or unreadable, the system asks for re-upload."
        raise HTTPException(
            status.HTTP_400_BAD_REQUEST, 
            "The image could not be read. Please take or choose the photo again.",
        )


def _as_utc(dt: datetime) -> datetime:
    # SQLite (tests) returns naive UTC datetimes; Postgres returns aware ones.
    return dt if dt.tzinfo else dt.replace(tzinfo=timezone.utc)
 
 
def claim_upload(
    db: Session,
    file_id: str,
    claim_token: Optional[str],
    user,
    allowed_purposes: Iterable[str],
) -> Upload:
    """Attach a file uploaded before the account existed to that account.
 
    Registration flow (Hoyohoy): the app uploads first and gets
    {file_id, claim_token}; the register request sends both back; the
    router creates the user, then calls this and stores file_url(file_id)
    in users.id_document_url / organizations.legitimacy_document_url.
 
    The token proves the caller is the one who uploaded the file, so a
    leaked or guessed file_id alone can't be attached to another account.
    Every failure gives the same message, so nothing leaks about the file.
    """
    not_found = HTTPException(
        status.HTTP_400_BAD_REQUEST,
        "The uploaded file was not found or has expired. Please upload it again.",
    )
    up = db.query(Upload).filter(Upload.file_id == file_id).first()
    if up is None or up.purpose not in set(allowed_purposes):
        raise not_found
    if up.owner_user_id is not None:
        if up.owner_user_id == user.user_id:
            return up  # already theirs (e.g. uploaded while logged in)
        raise not_found
    if (
        not claim_token
        or up.claim_token_hash is None
        or not secrets.compare_digest(up.claim_token_hash, hash_token(claim_token))
        or _as_utc(up.created_at) < datetime.now(timezone.utc) - UNCLAIMED_TTL
    ):
        raise not_found
    up.owner_user_id = user.user_id
    up.claim_token_hash = None  # single use
    up.claimed_at = datetime.now(timezone.utc)
    return up
 
 
def purge_unclaimed(db: Session, older_than: timedelta = UNCLAIMED_TTL) -> int:
    """Delete ownerless files older than the TTL: abandoned registrations,
    and files whose account was deleted (RA 10173: don't keep personal
    data longer than needed). Run from a shell or a scheduled job:
 
        python -c "from core.database import SessionLocal; from core.uploads import purge_unclaimed; \\
        db = SessionLocal(); print(purge_unclaimed(db)); db.commit()"
    """
    cutoff = datetime.now(timezone.utc) - older_than
    rows = (
        db.query(Upload)
        .filter(Upload.owner_user_id.is_(None), Upload.created_at < cutoff)
        .all()
    )
    for row in rows:
        get_storage().delete(row.storage_key)
        db.delete(row)
    return len(rows)