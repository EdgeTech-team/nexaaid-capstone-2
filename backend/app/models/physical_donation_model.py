from models.item_model import Item
from models.report import DisasterReport
from models.guest_donor_model import GuestDonor
from models.user_rbac_model import User
from sqlalchemy import (
    Column, Integer, String, Numeric, Date, DateTime, ForeignKey, CheckConstraint, Text, Index,
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
            "(pack_count IS NULL OR pack_count > 0) AND (per_pack IS NULL OR per_pack > 0)"
            " AND (size_amount IS NULL OR size_amount > 0)",
            name="chk_physical_donations_breakdown",
        ),
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
        Index("idx_physical_donations_batch_addition", "batch_reference", "addition_no"),
        # The expiry check looks up Pending rows past their deadline.
        Index("idx_physical_donations_status_expires", "status", "expires_at"),
    )

    donation_id = Column(Integer, primary_key=True, autoincrement=True)
    user_id = Column(Integer, ForeignKey("users.user_id"), nullable=True)
    guest_donor_id = Column(Integer, ForeignKey("guest_donors.guest_donor_id"), nullable=True)
    report_id = Column(Integer, ForeignKey("disaster_reports.report_id"), nullable=False)
    item_id = Column(Integer, ForeignKey("items.item_id"), nullable=False)
    packaging = Column(String(100), nullable=False)
    # Total in the item's base unit (kg, L, pcs...). With the breakdown
    # below it is worked out by the server: pack_count x per_pack x
    # size_amount, rounded to a whole unit (services/units.py).
    quantity = Column(Integer, nullable=False)
    # How the donor described it (Oct 2026, per-item fulfillment), e.g.
    # 3 boxes x 16 x 1.5 L bottle. NULL for donations from older apps, which
    # sent the total only. Migration 9b3f7c1d2e48.
    pack_count = Column(Integer, nullable=True)
    per_pack = Column(Integer, nullable=True)
    size_amount = Column(Numeric(12, 4), nullable=True)   # one piece, in the base unit
    size_label = Column(String(60), nullable=True)        # "1.5 L bottle", "25 kg sack"
    estimated_value = Column(Numeric(10, 2), nullable=True)
    handover_method = Column(String(20), nullable=False)
    pickup_address = Column(Text, nullable=True)
    # Door to Door map pin (UC-D2 alt 7c, section 3.1 "select his/her address")
    pickup_lat = Column(Numeric(9, 6), nullable=True)
    pickup_lng = Column(Numeric(9, 6), nullable=True)
    pickup_landmark = Column(Text, nullable=True)
    pickup_notes = Column(Text, nullable=True)
    # Door to Door: the days the donor is home for the pickup, as ISO weekday
    # numbers "1,3,5" (1 = Monday). Pickups happen within the CSWS pickup
    # hours (schemas/physical_donation_schema.pickup_rules).
    pickup_days = Column(String(20), nullable=True)
    # Door to Door: the specific dates the donor is home, "2026-10-26,2026-10-28"
    # (calendar picker). When set, pickup_days holds their weekdays so older
    # screens and checks still read something sensible. NULL = weekday entry.
    pickup_dates = Column(String(400), nullable=True)
    # Door to Door: the date CSWS came but nobody was home ("Not home" on
    # the pickup map, Oct 12 pickup logic v2). The planner moves the stop to
    # the donor's next allowed day after this date. NULL = never missed.
    pickup_not_home_date = Column(Date, nullable=True)
    # Door to Door, older entries: one preferred date and time (UC-D2 alt 7c)
    preferred_pickup_at = Column(DateTime(timezone=True), nullable=True)
    qr_reference = Column(String(100), nullable=False, unique=True)
    # Shared by every item of one donation; this is what the QR encodes.
    batch_reference = Column(String(100), nullable=False)
    # Which part of the donation this item came with (Oct 23): 1 = the
    # original pledge, 2+ = items the donor added later to the SAME donation
    # (same batch_reference, same QR). Shown as "Batch 1", "Batch 2". The
    # item's own created_at is when it was added. Migration a1d4e7c9b2f5.
    addition_no = Column(Integer, nullable=False, server_default="1", default=1)
    status =Column(String(50), nullable=False, server_default="Pending")
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