from sqlalchemy import Column, Integer, String, DateTime, ForeignKey, CheckConstraint, Text
from sqlalchemy.sql import func
from core.database import Base

class Organization(Base):
    __tablename__ = "organizations"
    __table_args__ = (
        CheckConstraint(
            "status IN ('Pending','Approved','Rejected')",
            name="chk_organizations_status"
        ),
    )

    organization_id = Column(Integer, primary_key=True, autoincrement=True, nullable=False)
    org_name = Column(String(150), nullable=False)
    organization_type = Column(String(100), nullable=False)
    address = Column(Text, nullable=False)
    contact_person = Column(String(150), nullable=False)
    registration_no = Column(String(100), nullable=True, unique=True)  
    contact_email = Column(String(150), nullable=False)
    legitimacy_document_url = Column(Text, nullable=True)
    rejection_reason = Column(Text, nullable=True)   
    status = Column(String(20), nullable=False, server_default="Pending")
    approved_by_user_id = Column(Integer, ForeignKey("users.user_id", name="fk_org_approved_by", ondelete="SET NULL"), nullable=True)
    approved_at = Column(DateTime(timezone=True), nullable=True)
    created_at = Column(DateTime(timezone=True), server_default=func.now(), nullable=False)