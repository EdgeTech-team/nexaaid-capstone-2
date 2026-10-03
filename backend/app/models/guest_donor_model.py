# models/guest_donor_model.py
from sqlalchemy import Column, Integer, String, DateTime
from sqlalchemy.sql import func
from core.database import Base

class GuestDonor(Base):
    __tablename__ = "guest_donors"

    guest_donor_id  = Column(Integer, primary_key=True, autoincrement=True)
    full_name       = Column(String(150), nullable=False)
    contact_number  = Column(String(20), nullable=False)
    email           = Column(String(150), nullable=True)
    created_at      = Column(DateTime(timezone=True), server_default=func.now(), nullable=False)