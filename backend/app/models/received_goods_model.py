from sqlalchemy import Column, Integer, Text, DateTime, ForeignKey, CheckConstraint
from sqlalchemy.orm import relationship
from sqlalchemy.sql import func
from core.database import Base

class ReceivedGoods(Base):
    __tablename__ = "received_goods"
    __table_args__ = (
        CheckConstraint("actual_quantity > 0", name="received_goods_actual_quantity_check"),
    )
    
    receive_id = Column(Integer, primary_key=True, autoincrement=True)
    donation_id = Column(Integer, ForeignKey("physical_donations.donation_id"), nullable=False)
    actual_quantity = Column(Integer, nullable=False)
    received_by_user_id = Column(Integer, ForeignKey("users.user_id"), nullable=False)
    received_at = Column(DateTime(timezone=True), server_default=func.now(), nullable=False)
    notes = Column(Text, nullable=True)
    
    donation = relationship("PhysicalDonation")
    received_by = relationship("User")