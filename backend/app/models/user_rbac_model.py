from sqlalchemy import Column, Integer, String, Boolean, DateTime, ForeignKey, Text
from sqlalchemy.orm import relationship
from sqlalchemy.sql import func
from core.database import Base

class User(Base):
    __tablename__ = "users"

    user_id = Column(Integer, primary_key=True, autoincrement=True)
    first_name = Column(String(50), nullable=False)
    last_name = Column(String(50), nullable=False)
    contact_number = Column(String(15), nullable=False)
    email = Column(String(150), unique=True, nullable=False)
    password_hash = Column(String(255), nullable=False)
    role_id = Column(Integer, ForeignKey("roles.role_id", ondelete="RESTRICT"), nullable=False)
    organization_id = Column(Integer, ForeignKey("organizations.organization_id", ondelete="SET NULL"), nullable=True)
    assigned_barangay_id = Column(Integer, ForeignKey("barangays.barangay_id", ondelete="SET NULL"), nullable=True)
    id_document_url = Column(Text, nullable=True)
    is_active = Column(Boolean, server_default="true", nullable=False)
    created_at = Column(DateTime(timezone=True), server_default=func.now(), nullable=False)

    # NEW: government employee number (issued by the office, NOT our user_id). Internal roles only.
    employee_id = Column(String(30), unique=True, nullable=True)
    # NEW: true while the user still has an emailed temporary password
    must_change_password = Column(Boolean, server_default="false", nullable=False)

    role = relationship("Role")