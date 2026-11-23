# core/reference_data/city_model.py
from sqlalchemy import Column, Integer, String
from core.shared.database import Base

class City(Base):
    __tablename__ = "cities"

    city_id   = Column(Integer, primary_key=True, autoincrement=True)
    city_name = Column(String(100), nullable=False, unique=True)
    province  = Column(String(100), nullable=False, server_default="Cebu")