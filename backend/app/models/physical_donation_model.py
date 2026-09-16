from models.item_model import Item
from models.report_model import DisasterReport
from models.guest_donor_model import GuestDonor
from models.user_rbac_model import User
from sqlalchemy import Column, Integer, String, Numeric, DateTime, ForeignKey, CheckConstraint, Text  
from sqlalchemy.orm import relationship
from sqlalchemy.sql import func
from core.database import Base

class PhysicalDonation(Base):
    __tablename__ = "physical_donations"
    __table_args__ = (
        CheckConstraint("quantity > 0", name="physical_donations_quantity_check"),
        CheckConstraint(
            "handover_method::text = ANY (ARRAY['Drop Off', 'Door to Door']::text[])",
            name="physical_donations_handover_method_check",
        ),
        CheckConstraint(
            "(user_id IS NOT NULL AND guest_donor_id IS NULL) OR (user_id IS NULL AND guest_donor_id IS NOT NULL)",
            name="chk_donation_donor_source",
        ),
        CheckConstraint(
            "status::text = ANY (ARRAY['Pending', 'Received', 'Confirmed']::text[])",
            name="chk_physical_donations_status",
        ),
    )

    donation_id = Column(Integer, primary_key=True, autoincrement=True)
    user_id = Column(Integer, ForeignKey("users.user_id"), nullable=True)
    guest_donor_id = Column(Integer, ForeignKey("guest_donors.guest_donor_id"), nullable=True)
    report_id = Column(Integer, ForeignKey("disaster_reports.report_id"), nullable=False)
    item_id = Column(Integer, ForeignKey("items.item_id"), nullable=False)
    packaging = Column(String(100), nullable=False)
    quantity = Column(Integer, nullable=False)
    estimated_value = Column(Numeric(10,2), nullable=True)
    handover_method = Column(String(20), nullable=False)
    pickup_address = Column(Text, nullable=True)
    qr_reference = Column(String(100), nullable=False, unique=True)
    status = Column(String(50), nullable=False, server_default="Pending")
    created_at = Column(DateTime(timezone=True), server_default=func.now(), nullable=False)
    
    guest_donor = relationship("GuestDonor")
    donor = relationship("User")
    report = relationship("DisasterReport")
    item = relationship("Item")