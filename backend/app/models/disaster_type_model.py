# models/disaster_type_model.py
from sqlalchemy import Column, Integer, String, Text
from core.database import Base

class DisasterType(Base):
    __tablename__ = "disaster_types"

    disaster_type_id = Column(Integer, primary_key=True, autoincrement=True)
    type_name         = Column(String(100), nullable=False, unique=True)
    description       = Column(Text, nullable=True)