from sqlalchemy import Column, DateTime, ForeignKey, Integer, String
from sqlalchemy.sql import func
from core.database import Base


class EmailVerificationCode(Base):
    """NF-006 (D4): a 6-digit code emailed to confirm the account's email
    once. Same shape as password_reset_tokens: stored hashed, valid 15
    minutes, works once, 5 wrong tries. Migration b3d9e1f4a7c2."""
    __tablename__ = "email_verification_codes"

    code_id = Column(Integer, primary_key=True, autoincrement=True)
    user_id = Column(Integer, ForeignKey("users.user_id", ondelete="CASCADE"), nullable=False, index=True)
    code_hash = Column(String(64), nullable=False)
    expires_at = Column(DateTime(timezone=True), nullable=False)
    used_at = Column(DateTime(timezone=True), nullable=True)
    attempts = Column(Integer, nullable=False, server_default="0", default=0)
    created_at = Column(DateTime(timezone=True), server_default=func.now(), nullable=False)
