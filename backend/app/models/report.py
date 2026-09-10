"""
app/models/report.py

Module 3.4 — Report Management (Mariquit)

Models `disaster_reports` and `sms_report_metadata`, matching the real
Neon schema exactly (see DBeaver script). These are the tables this
module OWNS.

Also includes minimal STUB models for tables owned by teammates who
haven't merged their real models yet (disaster_types, barangays,
sitios). This follows the same pattern used for `Organization` in
the Foundation layer:

    - just the primary key + the columns THIS module needs
    - lets FK constraints and relationship() work today
    - when whoever owns that table merges their real model,
      DELETE the stub here and import the real one instead
      (two mapped classes can't point at the same table at once)

`User` is NOT stubbed here — the real one already exists at
app/models/user_rbac_model.py (Hoyohoy's 3.3) and is already wired
into app/alembic/env.py, so it's imported directly below.
"""

from sqlalchemy import (
    Column,
    Integer,
    String,
    Text,
    Numeric,
    TIMESTAMP,
    ForeignKey,
    CheckConstraint,
    func,
)
from sqlalchemy.orm import relationship

from core.database import Base

# The real User model already exists — models/user_rbac_model.py (Hoyohoy's
# 3.3) — and is already registered with Base via app/alembic/env.py. Import
# the real one instead of stubbing it: two classes mapping to the same
# 'users' table would crash SQLAlchemy with a mapper conflict the moment
# both get imported into the same process.
from models.user_rbac_model import User  # noqa: F401  (re-exported for convenience)


# ---------------------------------------------------------------------------
# STUB MODELS — delete each one once the real owner merges their model
# ---------------------------------------------------------------------------

class DisasterType(Base):
    """STUB — real owner: whoever models reference/lookup tables. Delete on merge."""
    __tablename__ = "disaster_types"

    disaster_type_id = Column(Integer, primary_key=True)
    name = Column(String(100))


class Barangay(Base):
    """STUB — real owner: whoever models reference/lookup tables. Delete on merge."""
    __tablename__ = "barangays"

    barangay_id = Column(Integer, primary_key=True)
    name = Column(String(100))


class Sitio(Base):
    """STUB — real owner: whoever models reference/lookup tables. Delete on merge."""
    __tablename__ = "sitios"

    sitio_id = Column(Integer, primary_key=True)
    name = Column(String(100))


# ---------------------------------------------------------------------------
# REAL MODELS — owned by this module (3.4)
# ---------------------------------------------------------------------------

class DisasterReport(Base):
    __tablename__ = "disaster_reports"

    report_id = Column(Integer, primary_key=True)

    user_id = Column(
        Integer, ForeignKey("users.user_id", ondelete="RESTRICT"), nullable=False
    )
    disaster_type_id = Column(
        Integer,
        ForeignKey("disaster_types.disaster_type_id", ondelete="RESTRICT"),
        nullable=False,
    )
    barangay_id = Column(
        Integer, ForeignKey("barangays.barangay_id", ondelete="RESTRICT"), nullable=False
    )
    sitio_id = Column(
        Integer, ForeignKey("sitios.sitio_id", ondelete="SET NULL"), nullable=True
    )

    description = Column(Text, nullable=True)
    affected_families = Column(Integer, nullable=True)
    assistance_needed = Column(Text, nullable=True)
    estimated_quantity = Column(Integer, nullable=True)

    source = Column(String(20), nullable=False)  # 'web' | 'mobile' | 'sms'

    ai_priority_score = Column(Numeric(5, 2), nullable=True)
    ai_recommendation = Column(Text, nullable=True)
    priority_level = Column(String(50), nullable=True)
    status = Column(String(50), nullable=False, server_default="Pending")
    ai_processed_at = Column(TIMESTAMP(timezone=True), nullable=True)

    # Validation audit trail (added via migration — see
    # migrations/xxxx_add_validation_audit_fields.py). Per Sequence
    # Diagram 4 / UC-02: who approved it, and why one was rejected.
    validated_by = Column(
        Integer, ForeignKey("users.user_id", ondelete="SET NULL"), nullable=True
    )
    rejection_reason = Column(Text, nullable=True)

    created_at = Column(TIMESTAMP(timezone=True), nullable=False, server_default=func.now())
    updated_at = Column(
        TIMESTAMP(timezone=True),
        nullable=False,
        server_default=func.now(),
        onupdate=func.now(),
    )

    __table_args__ = (
        CheckConstraint("source IN ('web','mobile','sms')", name="disaster_reports_source_check"),
    )

    # Relationships
    user = relationship("User", foreign_keys=[user_id])
    disaster_type = relationship("DisasterType")
    barangay = relationship("Barangay")
    sitio = relationship("Sitio")
    validator = relationship("User", foreign_keys=[validated_by])
    sms_metadata = relationship(
        "SmsReportMetadata",
        back_populates="report",
        uselist=False,          # one-to-one (report_id is UNIQUE on the other side)
        cascade="all, delete-orphan",
    )

    fulfillment = relationship(
        "ReportFulfillment",
        back_populates="report",
        uselist=False,
        cascade="all, delete-orphan",
    )

class SmsReportMetadata(Base):
    __tablename__ = "sms_report_metadata"

    sms_meta_id = Column(Integer, primary_key=True)

    report_id = Column(
        Integer,
        ForeignKey("disaster_reports.report_id", ondelete="CASCADE"),
        nullable=False,
        unique=True,
    )
    contact_number = Column(String(20), nullable=False)
    raw_message = Column(Text, nullable=False)
    encoded_by_user_id = Column(
        Integer, ForeignKey("users.user_id", ondelete="RESTRICT"), nullable=False
    )
    encoded_at = Column(TIMESTAMP(timezone=True), nullable=False, server_default=func.now())

    # Relationships
    report = relationship("DisasterReport", back_populates="sms_metadata")
    encoded_by = relationship("User", foreign_keys=[encoded_by_user_id])


class ReportFulfillment(Base):
    """
    Module 3.10/3.11 support — one row per report, tracking how much of
    the reported need has actually been delivered and confirmed.
 
    Created automatically when a report is validated (see
    validate_report in api/v1/reports.py) with total_items_needed
    seeded from the report's own estimated_quantity. Recalculated
    every time a delivery's receipt is confirmed (api/v1/deliveries.py).
    """
    __tablename__= "report_fulfillments"

    fulfillment_id = Column(Integer, primary_key=True)

    report_id = Column(
         Integer,
         ForeignKey("disaster_reports.report_id", ondelete="CASCADE"),
        nullable=False,
        unique=True,
    )
    total_items_needed = Column(Integer, nullable=False)
    total_items_delivered = Column(Integer, nullable=False, server_default="0")
    fulfillment_percentage = Column(Numeric(5,2), nullable=False, server_default="0.00")
    verification_status = Column(String(20), nullable=False, server_default="Not Started")
    verified_by_user_id = Column(Integer, ForeignKey("users.user_id", ondelete="SET NULL"), nullable=True)
    verified_at = Column(TIMESTAMP(timezone=True), nullable=True)

    __table_args__ = (
        CheckConstraint(
            "verification_status IN ('Not Started', 'Partial', 'Complete')",
            name="chk_report_fulfillments_status",
        ),
    )

    report = relationship("DisasterReport", back_populates="fulfillment")
    verified_by = relationship("User", foreign_keys=[verified_by_user_id])
