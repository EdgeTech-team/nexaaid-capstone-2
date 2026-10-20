from sqlalchemy import (
    Boolean, CheckConstraint, Column, DateTime, ForeignKey, Integer, Numeric, String,
    UniqueConstraint,
)
from sqlalchemy.orm import relationship
from sqlalchemy.sql import func, true
from core.database import Base

class Item(Base):
    __tablename__ = "items"

    item_id = Column(Integer, primary_key=True, autoincrement=True)
    item_name = Column(String(150), nullable=False, unique=True)
    category = Column(String(100), nullable=False)
    # The item's BASE UNIT (per-item fulfillment, Oct 2026): every quantity
    # of this item in the system (needs, donations, received goods,
    # inventory, deliveries) is a whole number in this unit. kg = weight,
    # L = volume, anything else is counted (pcs, cans, packs, kits...).
    # See services/units.py.
    unit_of_measure = Column(String(50), nullable=False)
    # False = kept for old records only, hidden from every dropdown
    # (e.g. the old "Drinking Water" in gallons). Migration 9b3f7c1d2e48.
    active = Column(Boolean, nullable=False, default=True, server_default=true())
    created_at = Column(DateTime(timezone=True), server_default=func.now(), nullable=False)

    sizes = relationship("ItemSize", order_by="ItemSize.sort_order", lazy="selectin")


class ItemSize(Base):
    """Common sizes of one piece of an item (e.g. Water: 500 ml bottle =
    0.5 L, 1.5 L bottle = 1.5 L; Rice: 25 kg sack = 25 kg). Fixed reference
    data maintained by the developers in database/seeds/demo_seed.sql.
    A donor picks one (or types a custom size) and the system works out
    packs x per pack x size = total in the item's base unit.
    Migration 9b3f7c1d2e48."""

    __tablename__ = "item_sizes"
    __table_args__ = (
        UniqueConstraint("item_id", "label", name="uq_item_sizes_item_label"),
        CheckConstraint("amount > 0", name="chk_item_sizes_amount"),
    )

    size_id = Column(Integer, primary_key=True, autoincrement=True)
    item_id = Column(Integer, ForeignKey("items.item_id", ondelete="CASCADE",
                                         name="fk_item_sizes_item_id"), nullable=False, index=True)
    label = Column(String(60), nullable=False)
    amount = Column(Numeric(12, 4), nullable=False)   # in the item's base unit
    sort_order = Column(Integer, nullable=False, server_default="0")
