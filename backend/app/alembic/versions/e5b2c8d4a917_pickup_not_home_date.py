"""Door to Door "Not home" date (Oct 12 notes, pickup logic v2)

physical_donations.pickup_not_home_date: the date CSWS came for a Door to
Door pickup and nobody was home. The pickup planner
(services/pickup_planner.py) then moves that stop to the donor's next
allowed day after this date. NULL = never missed (every existing row).

Additive, nullable, no default, no constraint: nothing that reads
physical_donations today changes. Safe to re-run (IF EXISTS / IF NOT EXISTS).

Revision ID: e5b2c8d4a917
Revises: a7c3e5f19b42
"""
from alembic import op


revision = "e5b2c8d4a917"
down_revision = "a7c3e5f19b42"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.execute("ALTER TABLE physical_donations ADD COLUMN IF NOT EXISTS pickup_not_home_date DATE")


def downgrade() -> None:
    op.execute("ALTER TABLE physical_donations DROP COLUMN IF EXISTS pickup_not_home_date")