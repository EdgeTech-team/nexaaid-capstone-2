# models/barangay_model.py
from sqlalchemy import Column, Integer, String, ForeignKey
from core.database import Base

class Barangay(Base):
    __tablename__ = "barangays"

    barangay_id   = Column(Integer, primary_key=True, autoincrement=True)
    barangay_name = Column(String(150), nullable=False, unique=True)
    city_id       = Column(Integer, ForeignKey("cities.city_id"), nullable=False)