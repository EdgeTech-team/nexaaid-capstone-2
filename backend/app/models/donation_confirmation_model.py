from sqlaclhemy import Column, Integer, String, DateTime ,ForeignKey
from sqlalchemy.sql import func
from core.database import Base

class DonationConfirmation(Base):
    __tablename__ = "donation_confirmations"
    __table_args__ = {"extend_existing": True}

    confirmation_id = Column(Integer, primary_key=True, autoincrement=True)
    donation_id = Column(Integer, ForeignKey("physical_donations.donation_id"), nullable=False)
    confirmed_by_user_id = Column(Integer, ForeignKey("users.user_id"), nullable=False)
    status = Column(String(20), nullable=False)
    notes = Column(String(200), nullable=True)
    confrimed_at = Column(DateTime(timezone=True), server_default=func.now(), nullable=False)
