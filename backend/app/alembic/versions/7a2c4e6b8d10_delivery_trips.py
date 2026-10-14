"""delivery trips: several reports on one truck

A trip groups ordinary deliveries (one report, one barangay each) that
leave together, e.g. three Banilad reports and two nearby barangays.
Additive: a new table and two nullable columns on deliveries. Existing
deliveries keep trip_id NULL and work exactly as before.

Revision ID: 7a2c4e6b8d10
Revises: 5e1b8c3d9f20 (donation expiry and cancellation)
"""
from alembic import op
import sqlalchemy as sa


revision = "7a2c4e6b8d10"
down_revision = "5e1b8c3d9f20"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "delivery_trips",
        sa.Column("trip_id", sa.Integer(), primary_key=True),
        sa.Column("trip_date", sa.TIMESTAMP(timezone=True), nullable=False),
        sa.Column("vehicle_details", sa.Text(), nullable=True),
        sa.Column("notes", sa.Text(), nullable=True),
        sa.Column("handled_by_user_id", sa.Integer(),
                  sa.ForeignKey("users.user_id", ondelete="RESTRICT"), nullable=False),
        sa.Column("created_at", sa.TIMESTAMP(timezone=True), nullable=False,
                  server_default=sa.text("now()")),
    )
    op.add_column("deliveries", sa.Column("trip_id", sa.Integer(), nullable=True))
    op.add_column("deliveries", sa.Column("stop_order", sa.Integer(), nullable=True))
    op.create_foreign_key(
        "fk_deliveries_trip_id", "deliveries", "delivery_trips",
        ["trip_id"], ["trip_id"], ondelete="SET NULL",
    )
    op.create_index("ix_deliveries_trip_id", "deliveries", ["trip_id"])


def downgrade() -> None:
    op.drop_index("ix_deliveries_trip_id", table_name="deliveries")
    op.drop_constraint("fk_deliveries_trip_id", "deliveries", type_="foreignkey")
    op.drop_column("deliveries", "stop_order")
    op.drop_column("deliveries", "trip_id")
    op.drop_table("delivery_trips")
