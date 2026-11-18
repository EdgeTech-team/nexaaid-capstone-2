"""
app/models/delivery.py
Models 'deliveries','delivery_items', 'delivery_items', and 'receipts',matching the real Neon schema exactly. These are the tables this module OWNS.

Also includes a minimal STUB for 'items' (delivery_items.item_id references it ) - same pattern as a DisasterType/Barangay/Sitio in models/report/report.py. Whoever owns inventory should replace this with their real model; delete this stub when that happens.
"""


from sqlalchemy import(
    Boolean,
    Column,
    Integer,
    String,
    Text,
    ForeignKey,
    CheckConstraint,
    UniqueConstraint,
    TIMESTAMP,
    false,
    func,
)

from sqlalchemy.orm import relationship
from core.database import Base
from models.item_model import Item  # noqa: F401
from models.barangay_model import Barangay  # noqa: F401
from models.sitio_model import Sitio  # noqa: F401
from models.upload_model import Upload  # noqa: F401  (receipts.signature_file_id -> uploads.file_id)

# module (3.10)

class Delivery(Base):

    __tablename__ = "deliveries"

    delivery_id = Column(Integer, primary_key=True)

    report_id = Column(
        Integer,ForeignKey("disaster_reports.report_id", ondelete="RESTRICT"), nullable=False
    )
    destination_barangay_id = Column(
        Integer, ForeignKey("barangays.barangay_id", ondelete="RESTRICT" ), nullable=False
    )

    destination_sitio_id = Column(
        Integer, ForeignKey("sitios.sitio_id", ondelete="SET NULL"), nullable=True
    )

    handled_by_user_id = Column(
        Integer, ForeignKey("users.user_id", ondelete="RESTRICT"), nullable=False
    )

    status = Column(String(50),nullable=False)# 'Preparing', >'In Transit' > 'Delivered' > 'Confirmed' (or 'Cancelled')

    delivery_date = Column(TIMESTAMP(timezone=True), nullable=False)
    created_at = Column(TIMESTAMP(timezone=True), nullable=False, server_default=func.now())

    # Several reports on one truck (api/v1/trips.py). NULL = a delivery made
    # on its own, exactly as before. stop_order: 1 = first barangay visited.
    trip_id = Column(
        Integer, ForeignKey("delivery_trips.trip_id", ondelete="SET NULL"), nullable=True, index=True
    )
    stop_order = Column(Integer, nullable=True)

    # Unexpected problems (api/v1/delivery_problems.py): a delivery that
    # cannot go ahead is Cancelled, its goods go back to stock, and the
    # reason is kept here (migration 9c4e2b7a1f35).
    cancelled_at = Column(TIMESTAMP(timezone=True), nullable=True)
    cancel_reason = Column(Text, nullable=True)

    # Deleted from the delivery list (Cancelled or Confirmed only, testing
    # Oct 27). The row stays for fulfillment and history; the lists and
    # counts hide it. Migration b7d3e9f1a2c4.
    deleted_at = Column(TIMESTAMP(timezone=True), nullable=True)
    deleted_by_user_id = Column(
        Integer,
        ForeignKey("users.user_id", ondelete="SET NULL", name="fk_deliveries_deleted_by"),
        nullable=True,
    )

    # J2 / NF-015 (team agreement A2): the 6-digit handover code made when
    # the delivery arrives. Only a keyed hash is kept (services/handover.py);
    # the code is shown once to CSWS Main Office (or the DRRMO user carrying
    # it) and never to the Barangay Receiving Representative. NULL = no code
    # yet, or the arrival was undone. Migration a8c3e5f7b9d1.
    handover_code_hash = Column(String(128), nullable=True)
    handover_code_created_at = Column(TIMESTAMP(timezone=True), nullable=True)

    __table_args__ = (
        CheckConstraint(
             "status IN ('Preparing','In Transit','Delivered', 'Confirmed', 'Cancelled')",
             name="deliveries_status_check",
        ),
    )

    # Relationships
    report = relationship("DisasterReport")
    destination_barangay = relationship("Barangay")
    destination_sitio = relationship("Sitio")
    handled_by = relationship("User", foreign_keys=[handled_by_user_id])
    items = relationship("DeliveryItem", back_populates="delivery", cascade="all, delete-orphan")
    receipt = relationship(
        "Receipt", back_populates="delivery", uselist=False, cascade="all, delete-orphan"
    )
    trip = relationship("DeliveryTrip", back_populates="deliveries")

    @property
    def has_discrepancy(self) -> bool:
        """J1 / NF-009: the barangay counted a different quantity than CSWS
        sent on at least one line. False before the receipt and for
        receipts saved before counting started."""
        return self.receipt is not None and self.receipt.has_discrepancy


class DeliveryTrip(Base):
    """One truck run that carries deliveries for several reports, e.g. three
    Banilad reports and two nearby barangays in one go.

    Each delivery inside keeps ONE report and ONE barangay, so stock per
    report, the barangay's own receipt confirmation (UC-B1 alt 3a) and
    fulfillment per report work exactly as for a single delivery. The trip
    only groups them: prepare together, leave together, one stop per
    barangay. Its status is worked out from its deliveries (api/v1/trips.py),
    so it can never disagree with them. No route optimisation (Limitation 6).
    """

    __tablename__ = "delivery_trips"

    trip_id = Column(Integer, primary_key=True)
    trip_date = Column(TIMESTAMP(timezone=True), nullable=False)   # planned departure
    vehicle_details = Column(Text, nullable=True)                  # e.g. "City truck, plate ABC 1234"
    notes = Column(Text, nullable=True)
    handled_by_user_id = Column(
        Integer, ForeignKey("users.user_id", ondelete="RESTRICT"), nullable=False
    )
    created_at = Column(TIMESTAMP(timezone=True), nullable=False, server_default=func.now())

    deliveries = relationship("Delivery", back_populates="trip", order_by="Delivery.stop_order")
    handled_by = relationship("User", foreign_keys=[handled_by_user_id])

class DeliveryItem(Base):
        __tablename__ = "delivery_items"

        delivery_item_id = Column (Integer, primary_key=True)

        delivery_id = Column(
            Integer, ForeignKey("deliveries.delivery_id", ondelete="CASCADE"),nullable=False
        )

        item_id = Column(
            Integer, ForeignKey ("items.item_id", ondelete="RESTRICT"), nullable=False
        )
        quantity = Column(Integer, nullable=False)

        __table_args__ = (
            CheckConstraint(quantity > 0, name="delivery_items_quantity_check"),
        )

        #Relationships
        delivery = relationship ("Delivery", back_populates="items")
        item = relationship("Item")
        allocations = relationship(
            "DeliveryAllocation", back_populates="delivery_item", cascade="all, delete-orphan"
        )
        # J1 / NF-009: the barangay's count for this line. Read-only here: the
        # row is written through Receipt.items and removed by the database
        # (ON DELETE CASCADE), so this side never changes it.
        receipt_item = relationship("ReceiptItem", uselist=False, viewonly=True)

        @property
        def received_quantity(self):
            """What the barangay counted; None until it confirms, and for
            receipts saved before counting started."""
            return self.receipt_item.received_quantity if self.receipt_item is not None else None

        @property
        def discrepancy_reason(self):
            return self.receipt_item.discrepancy_reason if self.receipt_item is not None else None

class Receipt(Base):
        __tablename__ = "receipts"

        receipt_id = Column (Integer, primary_key=True)

        delivery_id = Column (
            Integer, ForeignKey("deliveries.delivery_id", ondelete="CASCADE"),nullable=False,unique=True
        )
        received_by_user_id = Column(
            Integer, ForeignKey ("users.user_id", ondelete="RESTRICT"), nullable=False
        )

        received_at = Column (TIMESTAMP(timezone=True),nullable=False, server_default=func.now()
        )

        remarks = Column(Text, nullable=True)

        # J2 / NF-015 (team agreement A2): proof of receipt. NULL on receipts
        # saved before J2; the API requires name, position and signature for
        # every new receipt. Files are uploads (core/uploads.py purposes
        # receipt_signature and receipt_slip_photo), referenced by file_id;
        # ON DELETE RESTRICT keeps them while the receipt exists.
        # Migration a8c3e5f7b9d1.
        signer_name = Column(String(150), nullable=True)
        signer_position = Column(String(100), nullable=True)
        signature_file_id = Column(
            String(36),
            ForeignKey("uploads.file_id", ondelete="RESTRICT", name="fk_receipts_signature_file_id"),
            nullable=True, index=True,
        )
        slip_photo_file_id = Column(
            String(36),
            ForeignKey("uploads.file_id", ondelete="RESTRICT", name="fk_receipts_slip_photo_file_id"),
            nullable=True, index=True,
        )
        handover_verified = Column(Boolean, nullable=False, default=False, server_default=false())

        #relationships
        delivery = relationship ("Delivery", back_populates="receipt")
        received_by = relationship ("User", foreign_keys=[received_by_user_id])
        # J1 / NF-009: one count per delivery line. Empty for receipts saved
        # before counting started (they keep the sent quantity).
        items = relationship(
            "ReceiptItem", back_populates="receipt", cascade="all, delete-orphan",
            order_by="ReceiptItem.receipt_item_id",
        )

        @property
        def has_discrepancy(self) -> bool:
            return any(i.received_quantity != i.expected_quantity for i in self.items)

        @property
        def reference_no(self):
            """J2 / NF-015: the Acknowledgment Receipt number, e.g.
            AR-2026-000123 (year of received_at, receipt_id as 6 digits).
            Worked out, never stored."""
            if self.receipt_id is None or self.received_at is None:
                return None
            return f"AR-{self.received_at.year}-{self.receipt_id:06d}"


class ReceiptItem(Base):
    """J1 / NF-009 (team agreement Nov 18, 2026): what the Barangay
    Receiving Representative counted for one delivery line.

    expected_quantity   what CSWS sent (delivery_items.quantity), copied at
                        confirmation so the record never changes
    received_quantity   what the barangay counted (0 or more)
    discrepancy_reason  required when the two differ: "Over" when more
                        arrived; "Short", "Damaged" or "Wrong item" when
                        fewer arrived; empty when they match

    Fulfillment counts min(received_quantity, expected_quantity) as
    delivered (services/fulfillment.py). Migration f7b2d4e6a8c1."""

    __tablename__ = "receipt_items"
    __table_args__ = (
        UniqueConstraint("delivery_item_id", name="uq_receipt_items_delivery_item_id"),
        CheckConstraint("expected_quantity > 0", name="chk_receipt_items_expected"),
        CheckConstraint("received_quantity >= 0", name="chk_receipt_items_received"),
        CheckConstraint(
            "discrepancy_reason IS NULL"
            " OR discrepancy_reason IN ('Short', 'Damaged', 'Wrong item', 'Over')",
            name="chk_receipt_items_reason",
        ),
        CheckConstraint(
            "(received_quantity = expected_quantity AND discrepancy_reason IS NULL)"
            " OR (received_quantity > expected_quantity"
            " AND COALESCE(discrepancy_reason, '') = 'Over')"
            " OR (received_quantity < expected_quantity"
            " AND COALESCE(discrepancy_reason, '') IN ('Short', 'Damaged', 'Wrong item'))",
            name="chk_receipt_items_reason_fits",
        ),
    )

    receipt_item_id = Column(Integer, primary_key=True)
    receipt_id = Column(
        Integer,
        ForeignKey("receipts.receipt_id", ondelete="CASCADE", name="fk_receipt_items_receipt_id"),
        nullable=False, index=True,
    )
    delivery_item_id = Column(
        Integer,
        ForeignKey("delivery_items.delivery_item_id", ondelete="CASCADE",
                   name="fk_receipt_items_delivery_item_id"),
        nullable=False,
    )
    expected_quantity = Column(Integer, nullable=False)
    received_quantity = Column(Integer, nullable=False)
    discrepancy_reason = Column(String(20), nullable=True)
    discrepancy_note = Column(Text, nullable=True)

    receipt = relationship("Receipt", back_populates="items")
    delivery_item = relationship("DeliveryItem")


class DeliveryAllocation(Base):
    """Whose goods went on a delivery (Oct 13 concerns, delivery
    preparation). Stock is pooled per report and item, so when CSWS sends
    65 of 80 kg the system records which donations they came from: first
    received, first sent, CMO-acknowledged donations before the others
    (services/delivery_allocation.py). A donor's step (In transit /
    Delivered / Barangay confirmed) follows these rows. Cancelled
    deliveries are ignored, so their goods count as unsent again.

    Migration c6d2a8e4f1b7."""

    __tablename__ = "delivery_allocations"
    __table_args__ = (
        CheckConstraint("quantity > 0", name="chk_delivery_allocations_quantity"),
    )

    allocation_id = Column(Integer, primary_key=True)
    delivery_item_id = Column(
        Integer,
        ForeignKey("delivery_items.delivery_item_id", ondelete="CASCADE",
                   name="fk_delivery_allocations_delivery_item_id"),
        nullable=False, index=True,
    )
    donation_id = Column(
        Integer,
        ForeignKey("physical_donations.donation_id", ondelete="CASCADE",
                   name="fk_delivery_allocations_donation_id"),
        nullable=False, index=True,
    )
    quantity = Column(Integer, nullable=False)

    delivery_item = relationship("DeliveryItem", back_populates="allocations")
