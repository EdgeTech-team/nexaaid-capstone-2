from sqlalchemy import Column, Integer, String, DateTime, ForeignKey
from sqlalchemy.sql import func
from core.database import Base

class ReportFulfillment(Base):
    __tablename__ = "report_fulfillments"
    __table_args__ = {"extend_existing": True}

    fulfillment_id = Column(Integer, primary_key=True, autoincrement=True)
    report_id = Column(Integer, ForeignKey("disaster_reports.report_id"), nullable=False)
    total_items_needed = Column(Integer, nullable=False)
    total_items_delivered = Column(Integer, nullable=False, server_default="0")
    fulfillment_percentage = Column(Integer, nullable=False, server_default="0.00")
    verification_status = Column(String(20), nullable=False)
    verified_by_user_id = Column(Integer, ForeignKey("users.user_id"), nullable=True)
    verified_at = Column(DateTime(timezone=True), nullable=True)
