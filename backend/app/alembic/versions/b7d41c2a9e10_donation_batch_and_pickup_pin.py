"""physical donations: one QR per donation batch + pickup map pin

Manuscript UC-D2 step 6 / Physical Donation module: "The system generates a
unique QR-based donation reference" per donation, however many items it has.
Each item stays its own physical_donations row (data dictionary, Table 39),
and rows submitted together share one batch_reference, which the QR encodes.

UC-D2 alt 7c / section 3.1: Door to Door donors pin their pickup location,
stored as pickup_lat / pickup_lng plus an optional landmark note.

Additive only: no column is renamed or dropped. Existing rows get
batch_reference = qr_reference, so every QR already printed still scans.

Revision ID: b7d41c2a9e10
Revises: a7c3e91b5d24 (add_barangay_donation_methods)
"""
from alembic import op
import sqlalchemy as sa


revision = "b7d41c2a9e10"
down_revision = "a7c3e91b5d24"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column(
        "physical_donations",
        sa.Column("batch_reference", sa.String(length=100), nullable=True),
    )
    op.execute(
        "UPDATE physical_donations SET batch_reference = qr_reference "
        "WHERE batch_reference IS NULL"
    )
    op.alter_column("physical_donations", "batch_reference", nullable=False)
    op.create_index(
        "idx_physical_donations_batch", "physical_donations", ["batch_reference"]
    )

    op.add_column(
        "physical_donations",
        sa.Column("pickup_lat", sa.Numeric(precision=9, scale=6), nullable=True),
    )
    op.add_column(
        "physical_donations",
        sa.Column("pickup_lng", sa.Numeric(precision=9, scale=6), nullable=True),
    )
    op.add_column(
        "physical_donations",
        sa.Column("pickup_landmark", sa.Text(), nullable=True),
    )
    op.create_check_constraint(
        "chk_pickup_coords_pair",
        "physical_donations",
        "(pickup_lat IS NULL) = (pickup_lng IS NULL)",
    )


def downgrade() -> None:
    op.drop_constraint("chk_pickup_coords_pair", "physical_donations", type_="check")
    op.drop_column("physical_donations", "pickup_landmark")
    op.drop_column("physical_donations", "pickup_lng")
    op.drop_column("physical_donations", "pickup_lat")
    op.drop_index("idx_physical_donations_batch", table_name="physical_donations")
    op.drop_column("physical_donations", "batch_reference")