# models/organization_model.py — unchanged from before, already had legitimacy_document_url
from sqlalchemy import Column, Integer, String, Text, DateTime, ForeignKey
from sqlalchemy.sql import func
from core.database import Base

class Organization(Base):
    __tablename__ = "organizations"

    organization_id = Column(Integer, primary_key=True, autoincrement=True)
    org_name = Column(String(150), nullable=False)
    organization_type = Column(String(100), nullable=False)
    address = Column(Text, nullable=False)
    contact_person = Column(String(150), nullable=False)
    registration_no = Column(String(100), unique=True, nullable=False)
    contact_email = Column(String(150), nullable=False)
    legitimacy_document_url = Column(Text, nullable=True)
    status = Column(String(20), nullable=False, server_default="Pending")
    approved_by_user_id = Column(Integer, ForeignKey("users.user_id", ondelete="SET NULL"), nullable=True)
    approved_at = Column(DateTime(timezone=True), nullable=True)
    created_at = Column(DateTime(timezone=True), server_default=func.now(), nullable=False)