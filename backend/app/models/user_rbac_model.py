# models/user_rbac_model.py — full corrected version
from sqlalchemy import Column, Integer, String, Boolean, DateTime, ForeignKey, Text
from sqlalchemy.orm import relationship
from sqlalchemy.sql import func
from core.database import Base

class User(Base):
    __tablename__ = "users"

    user_id = Column(Integer, primary_key=True, autoincrement=True)
    first_name = Column(String(50), nullable=False)
    last_name = Column(String(50), nullable=False)
    contact_number = Column(String(15), nullable=False)  # real column is VARCHAR(15)
    email = Column(String(150), unique=True, nullable=False)  # length matches real column
    password_hash = Column(String(255), nullable=False)
    role_id = Column(Integer, ForeignKey("roles.role_id", ondelete="RESTRICT"), nullable=False)
    organization_id = Column(Integer, ForeignKey("organizations.organization_id", ondelete="SET NULL"), nullable=True)
    assigned_barangay_id = Column(Integer, ForeignKey("barangays.barangay_id", ondelete="SET NULL"), nullable=True)  # NEW — column now exists in Neon
    id_document_url = Column(Text, nullable=True)  # front of the valid ID (UC-D1 step 3)
    # Kind of valid ID (schemas/user_schema.ID_TYPES). Donors only; migration f3dd12dbc3d7.
    id_type = Column(String(40), nullable=True)
    is_active = Column(Boolean, server_default="true", nullable=False)
    # Government employee number issued by the office (NOT user_id). Required for
    # internal accounts (UC-A1). Already in Neon: migration da126cd397f0.
    employee_id = Column(String(30), unique=True, nullable=True)
    # True while the user still has a temporary password (adviser item 3, da126cd397f0).
    must_change_password = Column(Boolean, default=False, server_default="false", nullable=False)
    created_at = Column(DateTime(timezone=True), server_default=func.now(), nullable=False)

    role = relationship("Role")