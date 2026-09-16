from sqlalchemy import Column, Integer, String, Boolean, DateTime, ForeignKey, Text
from sqlalchemy.orm import relationship
from sqlalchemy.sql import func
from core.database import Base
from models.role_model import Role

class User(Base):
    __tablename__ = "users"
    
    user_id = Column(Integer, primary_key=True, autoincrement=True)
    first_name = Column(String(50), nullable=False)
    last_name = Column(String(50), nullable=False)
    contact_number = Column(String(15), nullable=False)
    email = Column(String, unique=True, nullable=False)
    password_hash = Column(String(255), nullable=False)
    role_id = Column(Integer, ForeignKey("roles.role_id", ondelete = "RESTRICT"), nullable=False)
    organization_id = Column(Integer, ForeignKey("organizations.organization_id", ondelete = "SET NULL"), nullable=True)
    id_document_url = Column(Text, nullable=True)
    is_active = Column(Boolean, server_default="true", nullable=False)
    created_at = Column(DateTime(timezone=True), server_default=func.now(), nullable=False)
    assigned_barangay_id = Column(Integer, ForeignKey("barangays.barangay_id", ondelete = "SET NULL"), nullable=True)
    
    role = relationship("Role")