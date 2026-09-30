from sqlalchemy import Column, Integer, DateTime, ForeignKey, UniqueConstraint
from sqlalchemy.orm import relationship
from sqlalchemy.sql import func
from core.database import Base


class Inventory(Base):
    __tablename__ = "inventory"
    __table_args__ = (
        UniqueConstraint("item_id", "report_id", name="uq_inventory_item_report"),
    )

    inventory_id = Column(Integer, primary_key=True, autoincrement=True)
    item_id = Column(Integer, ForeignKey("items.item_id", ondelete="RESTRICT"), nullable=False)
    report_id = Column(Integer, ForeignKey("disaster_reports.report_id", ondelete="RESTRICT"), nullable=False)
    quantity = Column(Integer, nullable=False)
    last_updated = Column(DateTime(timezone=True), server_default=func.now(), onupdate=func.now(), nullable=False)

    item = relationship("Item")
    report = relationship("DisasterReport")