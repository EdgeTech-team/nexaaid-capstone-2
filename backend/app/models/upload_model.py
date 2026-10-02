"""
models/upload_model.py — Sprint 0 foundation: upload service (Castillo).
 
One row per uploaded file. The bytes live in storage (core/storage.py),
never in Postgres, so Neon stays small.
 
Private files (valid ID front/back, organization legitimacy documents)
are sensitive personal information under the Data Privacy Act
(RA 10173). They are only ever served through GET /uploads/{file_id}
after an owner / Administrator check — never from a public URL.
 
Every constraint and index is NAMED here and in the migration, so a
future `alembic revision --autogenerate` sees no difference and does
not try to drop/recreate them (the problem with revision 142a5db2006c).
"""
from sqlalchemy import (
    CheckConstraint,
    Column,
    DateTime,
    ForeignKey,
    Integer,
    String,
    UniqueConstraint,
)

from sqlalchemy.sql import func
from core.database import Base


class Upload(Base):
    __tablename__ = "uploads"
    __table_args__ = (
        CheckConstraint("visibility IN ('private', 'public')", name="chk_uploads_visibility"),
        CheckConstraint("size_bytes > 0", name="chk_uploads_size"),
        UniqueConstraint("storage_key", name="uq_uploads_storage_key"),
    )
    
    upload_id = Column(Integer, primary_key=True, autoincrement=True)
    # Random UUID shown to clients. Sequential ids would let anyone guess
    # other people's files, so upload_id never leaves the backend.
    file_id = Column(String(36), nullable=False, unique=True, index=True)
    purpose = Column(String(40), nullable=False)        # see core/uploads.PURPOSES
    visibility = Column(String(10), nullable=False)     # 'private' | 'public'
    content_type = Column(String(50), nullable=False)   # sniffed from bytes, not trusted from client
    
    size_bytes = Column(Integer, nullable=False)
    sha256 = Column(String(64), nullable=False)
    storage_key = Column(String(255), nullable=False)
    # NULL until the file is claimed. Registration uploads happen before
    # the account exists, so they start ownerless with a claim token.
    
    owner_user_id = Column(
        Integer,
        ForeignKey("users.user_id", ondelete="SET NULL"), name = "fk_uploads_owner_user_id",
        nullable=True,
        index=True,
    )
    claim_token_hash = Column(String(64), nullable=True)        # sha256 of the token; raw token is never stored
    
    claimed_at = Column(DateTime(timezone=True), nullable=True)
    created_at = Column(DateTime(timezone=True), server_default=func.now(), nullable=False)