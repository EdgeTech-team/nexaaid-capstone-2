from sqlalchemy import Column, Integer, String
from core.database import Base

class Organization(Base):
    __tablename__ = "organizations"
    
    organization_id = Column(Integer, primary_key=True, autoincrement=True)
    organization_name = Column(String(150), nullable=False)