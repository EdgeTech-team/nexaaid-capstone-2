from sqlalchemy import Column, Integer, String, DateTime, ForeignKey
from sqlalchemy.sql import func
from core.database import Base

class PhysicalDonation(Base):
    __tablename__ = "physical_donations"
    
    donation_id = Column(Integer, primary_key=True, autoincrement=True)
    user_id = Column(Integer, ForeignKey("users.user_id"), nullable=False)
    organization_id = Column(Integer, ForeignKey("organizations.organization_id"), nullable=True)
    report_id = Column(Integer, ForeignKey("disaster_reports.report_id"), nullable=False)
    Item_id = Column(Integer, nullable=False)
    packaging = Column(String(50), nullable=True)
    quantity = Column(Integer, nullable=False)
    estimated_value = Column(Integer, nullable=True)
    handover_method = Column(String(30), nullable=False)
    pickup_adress = Column(String(200), nullable=True)
    qr_reference = Column(String(100), nullable=False)
    status = Column(String(20), nullable=False, default="pending")
    created_at = Column(DateTime(timezone=True), server_default=func.now(), nullable=False)
    