from sqlalchemy import Column, Integer, String, DateTime, ForeignKey, CheckConstraint, Text
from sqlalchemy.sql import func
from core.config.database import Base

class Organization(Base):
    __tablename__ = "organizations"
    __table_args__ = (
        CheckConstraint(
            "status IN ('Pending','Approved','Rejected')",
            name="chk_organizations_status"
        ),
        CheckConstraint(
            "organization_category IN ('Government', 'Non-government')",
            name="chk_organizations_category",
        ),
    )

    organization_id = Column(Integer, primary_key=True, autoincrement=True, nullable=False)
    org_name = Column(String(150), nullable=False)
    organization_type = Column(String(100), nullable=False)
    # NF-008 (D6): Government or Non-government, set from organization_type
    # (schemas/organization_schema.ORGANIZATION_TYPES). Migration d4a7b2e8c6f1.
    organization_category = Column(String(20), nullable=False,
                                   server_default="Non-government", default="Non-government")
    address = Column(Text, nullable=True)
    contact_person = Column(String(150), nullable=False)
    registration_no = Column(String(100), nullable=True, unique=True)  
    contact_email = Column(String(150), nullable=False)
    legitimacy_document_url = Column(Text, nullable=True)
    rejection_reason = Column(Text, nullable=True)   
    status = Column(String(20), nullable=False, server_default="Pending")
    approved_by_user_id = Column(Integer, ForeignKey("users.user_id", name="fk_org_approved_by", ondelete="SET NULL"), nullable=True)
    approved_at = Column(DateTime(timezone=True), nullable=True)
    reviewed_at = Column(DateTime(timezone=True), nullable=True)
    reviewed_by_user_id = Column(
        Integer,
        ForeignKey("users.user_id", name="fk_org_reviewed_by", ondelete="SET NULL"),
        nullable=True,
    )
    created_at = Column(DateTime(timezone=True), server_default=func.now(), nullable=False)