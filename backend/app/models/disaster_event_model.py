# models/disaster_event_model.py
from sqlalchemy import TIMESTAMP, Column, ForeignKey, Integer, String, func

from core.database import Base


class DisasterEvent(Base):
    """NF-003 (Nov 2026): one disaster that hit several barangays, e.g.
    "Earthquake - Nov 9, 2026". The CSWS Disaster Unit fills in ONE form
    for all the barangays; the system still saves one disaster report per
    barangay (own families, needs, validation, priority, deliveries and
    fulfillment) and links them here with disaster_reports.event_id.
    Single-barangay reports have no event. Migration e4f1a9c3b7d2."""

    __tablename__ = "disaster_events"

    event_id = Column(Integer, primary_key=True, autoincrement=True)
    event_name = Column(String(150), nullable=False)
    disaster_type_id = Column(
        Integer,
        ForeignKey("disaster_types.disaster_type_id", ondelete="RESTRICT",
                   name="fk_disaster_events_disaster_type_id"),
        nullable=False,
    )
    # What kind of disaster, when the type is "Other" (e.g. "Gas leak").
    disaster_type_other = Column(String(100), nullable=True)
    created_by_user_id = Column(
        Integer,
        ForeignKey("users.user_id", ondelete="RESTRICT",
                   name="fk_disaster_events_created_by_user_id"),
        nullable=False,
    )
    created_at = Column(TIMESTAMP(timezone=True), nullable=False, server_default=func.now())
