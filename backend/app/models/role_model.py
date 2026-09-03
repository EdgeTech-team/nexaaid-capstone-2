from sqlalchemy import Column, Integer, String, DateTime
from sqlalchemy.sql import func
from core.database import Base

class Role(Base):
    __tablename__ = "roles"
    
    role_id = Column(Integer, primary_key=True, autoincrement=True)
    role_name = Column(String(100), unique=True, nullable=False)
    created_at = Column(DateTime(timezone=True), server_default=func.now(), nullable=False)
    