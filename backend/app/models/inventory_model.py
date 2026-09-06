from sqlalchemy import Column, Integer, String, DateTime ,ForeignKey
from sqlalchemy.sql import func
from core.database import Base

class Inventory(Base):
    __tablename__ = "inventory"
    __table_args__ = {"extend_existing": True}

    inventory_id = Column(Integer, primary_key=True, autoincrement=True)
    item_id = Column(Integer, ForeignKey("items.item_id"), nullable=False)
    report_id = Column(Integer, ForeignKey("disaster_reports.report_id"), nullable=False)
    quantity = Column(Integer, nullable=False, server_default="0")
    last_updated = Column(DateTime(timezone=True), server_default=func.now(), onupdate=func.now(), nullable=False)