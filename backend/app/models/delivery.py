"""
app/models/delivery.py
Models 'deliveries','delivery_items', 'delivery_items', and 'receipts',matching the real Neon schema exactly. These are the tables this module OWNS.

Also includes a minimal STUB for 'items' (delivery_items.item_id references it ) - same pattern as a DisasterType/Barangay/Sitio in models/report/report.py. Whoever owns inventory should replace this with their real model; delete this stub when that happens.
"""


from sqlalchemy import(
    Column,
    Integer,
    String,
    Text,
    ForeignKey,
    CheckConstraint,
    UniqueConstraint,
    TIMESTAMP,
    func,
)

from sqlalchemy.orm import relationship
from core.database import Base
from models.item_model import Item  # noqa: F401
from models.barangay_model import Barangay  # noqa: F401
from models.sitio_model import Sitio  # noqa: F401

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

    status = Column(String(50),nullable=False)# 'Preparing', >'In Transit' > 'Delivered' > 'Confirmed'

    delivery_date = Column(TIMESTAMP(timezone=True), nullable=False)
    created_at = Column(TIMESTAMP(timezone=True), nullable=False, server_default=func.now())

    __table_args__ = (
        CheckConstraint(
             "status IN ('Preparing','In Transit','Delivered', 'Confirmed')", 
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

        #relationships
        delivery = relationship ("Delivery", back_populates="receipt")
        received_by = relationship ("User", foreign_keys=[received_by_user_id])