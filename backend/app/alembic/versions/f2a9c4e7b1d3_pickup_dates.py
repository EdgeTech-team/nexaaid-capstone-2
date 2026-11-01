"""Door to Door pickup on specific dates (calendar picker)

physical_donations.pickup_dates: the dates the donor is home, as ISO dates
"2026-10-26,2026-10-28". Replaces choosing weekdays in the app; rows made
before keep pickup_days only and still work (NULL here).

Additive, nullable, no default, no constraint. Safe to re-run
(IF EXISTS / IF NOT EXISTS).

Revision ID: f2a9c4e7b1d3
Revises: 7f4d2b9e6a31
"""
from alembic import op


revision = "f2a9c4e7b1d3"
down_revision = "7f4d2b9e6a31"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.execute("ALTER TABLE physical_donations ADD COLUMN IF NOT EXISTS pickup_dates VARCHAR(400)")


def downgrade() -> None:
    op.execute("ALTER TABLE physical_donations DROP COLUMN IF EXISTS pickup_dates")
