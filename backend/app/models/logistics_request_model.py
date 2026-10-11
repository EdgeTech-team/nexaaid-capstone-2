from sqlalchemy import Column, Integer, String, Text, Date, DateTime, ForeignKey, CheckConstraint
from sqlalchemy.sql import func
from core.database import Base

class LogisticsRequest(Base):
    """A request for DRRMO transport support (UC-DR1).

    request_type 'Delivery': CSWS Main Office needs a truck for a delivery
    it is preparing (UC-CM2 alt 3a); delivery_id is set.
    request_type 'Pickup': the CSWS Disaster Unit needs help with a Door to
    Door pickup run it planned on the pickup map; there is no delivery, the
    run is pickup_date plus the donation entries in pickup_batches.
    """
    __tablename__ = "logistics_requests"
    __table_args__ = (
        CheckConstraint("request_type IN ('Delivery', 'Pickup')", name="chk_logistics_request_type"),
        CheckConstraint(
            "(request_type = 'Delivery' AND delivery_id IS NOT NULL) OR "
            "(request_type = 'Pickup' AND delivery_id IS NULL AND pickup_date IS NOT NULL)",
            name="chk_logistics_request_shape",
        ),
    )

    request_id = Column(Integer, primary_key=True, autoincrement=True)
    delivery_id = Column(Integer, ForeignKey("deliveries.delivery_id", ondelete="RESTRICT"), nullable=True)
    requested_by_user_id = Column(Integer, ForeignKey("users.user_id", ondelete="RESTRICT"), nullable=False)
    assigned_to_user_id = Column(Integer, ForeignKey("users.user_id", ondelete="SET NULL"), nullable=True)
    status = Column(String(30), nullable=False, server_default="Pending")
    scheduled_date = Column(DateTime(timezone=True), nullable=True)
    notes = Column(Text, nullable=True)
    created_at = Column(DateTime(timezone=True), server_default=func.now(), nullable=False)
    request_type = Column(String(20), nullable=False, server_default="Delivery")
    # Pickup runs only: the day, and the QR batch references in stop order.
    pickup_date = Column(Date, nullable=True)
    pickup_batches = Column(Text, nullable=True)

    @property
    def batch_list(self) -> list:
        return [b for b in (self.pickup_batches or "").split(",") if b]

    @property
    def title(self) -> str:
        """What the request is for, in notifications: "delivery #12" or
        "Door to Door pickups on Wed, Oct 14 (5 stops)"."""
        if self.request_type == "Pickup":
            n = len(self.batch_list)
            day = self.pickup_date.strftime("%a, %b %d").replace(" 0", " ") if self.pickup_date else ""
            return f"Door to Door pickups on {day} ({n} stop{'s' if n != 1 else ''})"
        return f"delivery #{self.delivery_id}"
