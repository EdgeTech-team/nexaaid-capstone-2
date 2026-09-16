# models/report_model.py
from sqlalchemy import Column, Integer, String, Text, DateTime, Numeric, ForeignKey, CheckConstraint
from sqlalchemy.sql import func
from core.database import Base

class DisasterReport(Base):
    __tablename__ = "disaster_reports"
    __table_args__ = (
        CheckConstraint(
            "source::text = ANY (ARRAY['Web','Mobile','SMS']::text[])",
            name="disaster_reports_source_check",
        ),
        CheckConstraint(
            "status::text = ANY (ARRAY['Pending','Validated','Rejected','On Hold']::text[])",
            name="chk_disaster_reports_status",
        ),
        CheckConstraint(
            "priority_level IS NULL OR priority_level::text = ANY (ARRAY['Low','Medium','High','Critical']::text[])",
            name="chk_disaster_reports_priority",
        ),
        CheckConstraint(
            "status::text <> 'Rejected'::text OR rejection_reason IS NOT NULL",
            name="chk_disaster_reports_rejection_reason",
        ),
        CheckConstraint(
            "status::text <> ALL (ARRAY['Validated','Rejected']::text[]) OR validated_by IS NOT NULL",
            name="chk_disaster_reports_validated_by",
        ),
    )

    report_id           = Column(Integer, primary_key=True, autoincrement=True)
    user_id              = Column(Integer, ForeignKey("users.user_id"), nullable=False)
    disaster_type_id     = Column(Integer, ForeignKey("disaster_types.disaster_type_id"), nullable=False)
    barangay_id          = Column(Integer, ForeignKey("barangays.barangay_id"), nullable=False)
    sitio_id             = Column(Integer, ForeignKey("sitios.sitio_id"), nullable=True)
    description          = Column(Text, nullable=True)
    affected_families    = Column(Integer, nullable=True)
    assistance_needed    = Column(Text, nullable=True)
    estimated_quantity   = Column(Integer, nullable=True)
    source                = Column(String(20), nullable=False)
    ai_priority_score     = Column(Numeric(5, 2), nullable=True)
    ai_recommendation     = Column(Text, nullable=True)
    priority_level         = Column(String(50), nullable=True)
    status                 = Column(String(50), nullable=False, server_default="Pending")
    ai_processed_at        = Column(DateTime(timezone=True), nullable=True)
    created_at              = Column(DateTime(timezone=True), server_default=func.now(), nullable=False)
    updated_at              = Column(DateTime(timezone=True), server_default=func.now(), onupdate=func.now(), nullable=False)  # ← fixed: no trigger exists, SQLAlchemy handles it now
    validated_by            = Column(Integer, ForeignKey("users.user_id", ondelete="SET NULL"), nullable=True)
    rejection_reason        = Column(Text, nullable=True)