from models.item_model import Item
from models.report import DisasterReport
from models.guest_donor_model import GuestDonor
from models.user_rbac_model import User
from sqlalchemy import (
    Column, Integer, String, Numeric, DateTime, ForeignKey, CheckConstraint, Text, Index,
)
from sqlalchemy.orm import relationship
from sqlalchemy.sql import func
from core.database import Base


class PhysicalDonation(Base):
    """One row per donated item (data dictionary, Table 39).

    Items submitted together in one donation share a batch_reference, and
    the donor's single QR code encodes it (UC-D2 step 6). qr_reference stays
    unique per row ("<batch_reference>-<n>") so receiving, CMO confirmation,
    inventory and deliveries keep working per item (UC-CM1 alt 4a).
    """

    __tablename__ = "physical_donations"
    __table_args__ = (
        CheckConstraint("quantity > 0", name="physical_donations_quantity_check"),
        CheckConstraint(
            "handover_method IN ('Drop Off', 'Door to Door')",
            name="physical_donations_handover_method_check",
        ),
        CheckConstraint(
            "(user_id IS NOT NULL AND guest_donor_id IS NULL) OR (user_id IS NULL AND guest_donor_id IS NOT NULL)",
            name="chk_donation_donor_source",
        ),
        CheckConstraint(
            "status IN ('Pending', 'Received', 'Confirmed', 'Expired', 'Cancelled')",
            name="chk_physical_donations_status",
        ),
        CheckConstraint(
            "(pickup_lat IS NULL) = (pickup_lng IS NULL)",
            name="chk_pickup_coords_pair",
        ),
        Index("idx_physical_donations_batch", "batch_reference"),
        # The expiry check looks up Pending rows past their deadline.
        Index("idx_physical_donations_status_expires", "status", "expires_at"),
    )

    donation_id = Column(Integer, primary_key=True, autoincrement=True)
    user_id = Column(Integer, ForeignKey("users.user_id"), nullable=True)
    guest_donor_id = Column(Integer, ForeignKey("guest_donors.guest_donor_id"), nullable=True)
    report_id = Column(Integer, ForeignKey("disaster_reports.report_id"), nullable=False)
    item_id = Column(Integer, ForeignKey("items.item_id"), nullable=False)
    packaging = Column(String(100), nullable=False)
    quantity = Column(Integer, nullable=False)
    estimated_value = Column(Numeric(10, 2), nullable=True)
    handover_method = Column(String(20), nullable=False)
    pickup_address = Column(Text, nullable=True)
    # Door to Door map pin (UC-D2 alt 7c, section 3.1 "select his/her address")
    pickup_lat = Column(Numeric(9, 6), nullable=True)
    pickup_lng = Column(Numeric(9, 6), nullable=True)
    pickup_landmark = Column(Text, nullable=True)
    # Door to Door: when the donor would like CSWS to pick up (UC-D2 alt 7c)
    preferred_pickup_at = Column(DateTime(timezone=True), nullable=True)
    qr_reference = Column(String(100), nullable=False, unique=True)
    # Shared by every item of one donation; this is what the QR encodes.
    batch_reference = Column(String(100), nullable=False)
    status = Column(String(50), nullable=False, server_default="Pending")
    created_at = Column(DateTime(timezone=True), server_default=func.now(), nullable=False)

    # Termination of donations that never arrive (services/donation_expiry.py).
    # Pending items are handed over by expires_at, or the system marks them
    # 'Expired'. A donor (or CSWS for them) can mark them 'Cancelled'.
    # Closed rows are never deleted: they stay here for the records and audit.
    expires_at = Column(DateTime(timezone=True), nullable=True)
    reminder_sent_at = Column(DateTime(timezone=True), nullable=True)
    closed_at = Column(DateTime(timezone=True), nullable=True)
    close_reason = Column(Text, nullable=True)
    # NULL with closed_at set = closed automatically by the system.
    closed_by_user_id = Column(Integer, ForeignKey("users.user_id", ondelete="SET NULL"), nullable=True)

    guest_donor = relationship("GuestDonor")
    donor = relationship("User", foreign_keys=[user_id])
    report = relationship("DisasterReport")
    item = relationship("Item")