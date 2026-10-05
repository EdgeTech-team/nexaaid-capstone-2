"""
models/donation_info_model.py — where donors can send money directly to a
barangay (adviser item 7). DISPLAY ONLY: NexaAid never processes, holds or
verifies money (manuscript Scope Limitation #5).

Tables from migrations dcda2d8a846c and a7c3e91b5d24. Every constraint is
named here exactly as in the migrations, so autogenerate sees no difference.
"""
from sqlalchemy import CheckConstraint, Column, DateTime, ForeignKey, Integer, String
from sqlalchemy.orm import declared_attr
from sqlalchemy.sql import func

from core.database import Base

PROVIDERS = ("GCash", "Maya", "Bank", "Other")


class DonationInfoColumns:
    """Columns the donation-info tables share. Foreign keys and checks are declared per
    table so each gets its own constraint name (fk_<table>_..., chk_<table>_...)."""
    provider = Column(String(20), nullable=True)
    account_name = Column(String(100), nullable=True)
    account_number = Column(String(50), nullable=True)
    instructions = Column(String(500), nullable=True)
    updated_at = Column(DateTime(timezone=True), server_default=func.now(),
                        onupdate=func.now(), nullable=False)

    @declared_attr
    def qr_file_id(cls):
        # The QR image: an upload with purpose barangay_donation_qr (public).
        return Column(String(36), ForeignKey(
            "uploads.file_id", ondelete="SET NULL", name=f"fk_{cls.__tablename__}_qr_file_id"),
            nullable=True)

    @declared_attr
    def updated_by_user_id(cls):
        return Column(Integer, ForeignKey(
            "users.user_id", ondelete="SET NULL", name=f"fk_{cls.__tablename__}_updated_by"),
            nullable=True)

    @declared_attr
    def __table_args__(cls):
        t = cls.__tablename__
        return (
            CheckConstraint("provider IS NULL OR provider IN ('GCash', 'Maya', 'Bank', 'Other')",
                            name=f"chk_{t}_provider"),
            CheckConstraint(
                "qr_file_id IS NOT NULL OR account_number IS NOT NULL OR instructions IS NOT NULL",
                name=f"chk_{t}_has_info"),
        )


class BarangayDonationInfo(DonationInfoColumns, Base):
    """LEGACY (one record per barangay). Replaced by BarangayDonationMethod in
    migration a7c3e91b5d24, which copied these rows across. No longer read or
    written by the API; drop this table in a later migration."""
    __tablename__ = "barangay_donation_info"

    barangay_id = Column(Integer, ForeignKey(
        "barangays.barangay_id", ondelete="CASCADE", name="fk_barangay_donation_info_barangay"),
        primary_key=True)


class BarangayDonationMethod(DonationInfoColumns, Base):
    """One way a barangay can receive money (J3): its own provider, account
    details, instructions and QR. A barangay has any number of these. Edited by
    its Barangay Receiving Representative (own barangay only, like UC-B1 alt 3a)
    or the Administrator."""
    __tablename__ = "barangay_donation_methods"

    method_id = Column(Integer, primary_key=True, autoincrement=True)
    barangay_id = Column(Integer, ForeignKey(
        "barangays.barangay_id", ondelete="CASCADE", name="fk_barangay_donation_methods_barangay"),
        nullable=False, index=True)


class ReportDonationInfo(DonationInfoColumns, Base):
    """Override for one report, set by the CSWS Disaster Unit (UC-CD1).
    Without a row here the report shows its barangay's methods."""
    __tablename__ = "report_donation_info"

    report_id = Column(Integer, ForeignKey(
        "disaster_reports.report_id", ondelete="CASCADE", name="fk_report_donation_info_report"),
        primary_key=True)