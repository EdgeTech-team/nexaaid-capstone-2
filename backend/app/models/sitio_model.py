# models/sitio_model.py
from sqlalchemy import Column, Integer, String, ForeignKey
from core.database import Base

class Sitio(Base):
    __tablename__ = "sitios"

    sitio_id    = Column(Integer, primary_key=True, autoincrement=True)
    barangay_id = Column(Integer, ForeignKey("barangays.barangay_id"), nullable=False)
    sitio_name  = Column(String(150), nullable=False)