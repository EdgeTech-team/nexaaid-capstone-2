from sqlalchemy import Column, Integer, String, DateTime ,ForeignKey
from sqlalchemy.sql import func
from core.database import Base

class LogisticsRequest(Base):
    __tablename__ = "logistics_requests"
    __table_args__ = {"extend_existing": True}

    request_id = Column(Integer, primary_key=True, autoincrement=True)
    report_id = Column(Integer, ForeignKey("disaster_reports.report_id"), nullable=False)
    deliver_id = Column(Integer, ForeignKey("deliveries.delivery_id"), nullable=False)
    requested_by_user_id = Column(Integer, ForeignKey("users.user_id"), nullable=False)
    assigned_to_user_id = Column(Integer, ForeignKey("users.user_id"), nullable=True)
    status = Column(String(30), nullable=False, server_default="pending")
    scheduled_date = Column(DateTime(timezone=True), nullable=True)
    notes = Column(String(200), nullable=True)
    created_at = Column(DateTime(timezone=True), server_default=func.now(), nullable=False)