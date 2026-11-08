# models/barangay_hazard_model.py
from sqlalchemy import Column, ForeignKey, Index, Integer, String, UniqueConstraint
from core.database import Base

class BarangayHazard(Base):
    """A barangay known to be prone to a location-specific disaster type
    (NF-004, migration a4d8c2e6f1b9). Only a suggestion on the report form,
    never a restriction."""
    __tablename__ = "barangay_hazards"
    __table_args__ = (
        UniqueConstraint("barangay_id", "disaster_type_id",
                         name="uq_barangay_hazards_barangay_type"),
        Index("idx_barangay_hazards_type", "disaster_type_id"),
    )

    barangay_hazard_id = Column(Integer, primary_key=True, autoincrement=True)
    barangay_id = Column(Integer, ForeignKey("barangays.barangay_id", ondelete="CASCADE"),
                         nullable=False)
    disaster_type_id = Column(Integer, ForeignKey("disaster_types.disaster_type_id",
                                                  ondelete="CASCADE"), nullable=False)
    source = Column(String(150), nullable=True)
