# models/disaster_type_model.py
from sqlalchemy import Column, Integer, String, Text
from core.database import Base

# The type for a disaster not on the list. Reports of this type say what it
# was in disaster_reports.disaster_type_other (migration e2b6d4a8c1f9).
OTHER_DISASTER_TYPE = "Other"

class DisasterType(Base):
    __tablename__ = "disaster_types"

    disaster_type_id = Column(Integer, primary_key=True, autoincrement=True)
    type_name         = Column(String(100), nullable=False, unique=True)
    description       = Column(Text, nullable=True)