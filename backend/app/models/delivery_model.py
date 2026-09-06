from sqlaclhemy import Column, Integer, String, DateTime ,ForeignKey
from sqlalchemy.sql import func
from core.database import Base

class delivery(Base):
    __tablename__ = "deliveries"
    __table_args__ = {"extend_existing": True}

    delivery_id = Column(Integer, primary_key=True, autoincrement=True)
    report_id = Column(Integer, ForeignKey("disaster_reports.report_id"), nullable=False)
    destination_barangay_id = Column(Integer, nullable=False)
    destination_sitio_id = Column(Integer, nullable=True)
    handled_by_user_id = Column(Integer, ForeignKey("users.user_id"), nullable=False)
    status = Column(String(30), nullable=False)
    delivery_date = Column(DateTime(timezone=True), server_default=func.now(), nullable=False)
    created_at = Column(DateTime(timezone=True), server_default=func.now(), nullable=False)