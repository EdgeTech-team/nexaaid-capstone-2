# models/user_rbac_model.py
from sqlalchemy import Column, Integer, String, Boolean, DateTime, ForeignKey, Text, UniqueConstraint
from sqlalchemy.orm import relationship
from sqlalchemy.sql import func
from core.database import Base

class User(Base):
    __tablename__ = "users"
    # Usernames are saved in lowercase (core/usernames.py), so a plain unique
    # constraint is case-insensitive in practice. NULLs don't clash, so donors
    # and older accounts can leave it empty.
    __table_args__ = (UniqueConstraint("username", name="uq_users_username"),)

    user_id = Column(Integer, primary_key=True, autoincrement=True)
    first_name = Column(String(50), nullable=False)
    last_name = Column(String(50), nullable=False)
    contact_number = Column(String(15), nullable=False)  # real column is VARCHAR(15)
    email = Column(String(150), unique=True, nullable=False)  # length matches real column
    # Login name for organization accounts (the contact person's email is not
    # always the person using the account). Lowercase, 4 to 30 characters.
    username = Column(String(30), nullable=True)
    password_hash = Column(String(255), nullable=False)
    role_id = Column(Integer, ForeignKey("roles.role_id", ondelete="RESTRICT"), nullable=False)
    organization_id = Column(Integer, ForeignKey("organizations.organization_id", ondelete="SET NULL"), nullable=True)
    assigned_barangay_id = Column(Integer, ForeignKey("barangays.barangay_id", ondelete="SET NULL"), nullable=True)  # NEW — column now exists in Neon
    id_document_url = Column(Text, nullable=True)  # front of the valid ID (UC-D1 step 3)
    # Kind of valid ID (schemas/user_schema.ID_TYPES). Donors only; migration f3dd12dbc3d7.
    id_type = Column(String(40), nullable=True)
    address = Column(Text, nullable=True)  # optional home address (donors)
    is_active = Column(Boolean, server_default="true", nullable=False)
    # Why an Administrator deactivated the account, and when. Set together with
    # is_active = False and cleared when the account is activated again.
    # Accounts deactivated before this existed have both as NULL.
    deactivation_reason = Column(Text, nullable=True)
    deactivated_at = Column(DateTime(timezone=True), nullable=True)
    # Government employee number issued by the office (NOT user_id). Required for
    # internal accounts (UC-A1). Already in Neon: migration da126cd397f0.
    employee_id = Column(String(30), unique=True, nullable=True)
    must_change_password = Column(Boolean, default=False, server_default="false", nullable=False)
    terms_accepted_at = Column(DateTime(timezone=True), nullable=True)
    # The Administrator reviewed this individual donor's registration (review
    # only, like organizations.reviewed_at). Migration a7c3e5f19b42.
    reviewed_at = Column(DateTime(timezone=True), nullable=True)
    reviewed_by_user_id = Column(
        Integer,
        ForeignKey("users.user_id", name="fk_users_reviewed_by", ondelete="SET NULL"),
        nullable=True,
    )
    created_at = Column(DateTime(timezone=True), server_default=func.now(), nullable=False)

    role = relationship("Role")