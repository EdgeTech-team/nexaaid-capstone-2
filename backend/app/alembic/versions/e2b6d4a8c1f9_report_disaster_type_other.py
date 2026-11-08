"""Name of the disaster when a report's type is "Other" (Oct 2026)

The report form's disaster type dropdown lists Other last. Choosing it now
asks what kind of disaster it was (for example "Gas leak"), stored in
disaster_reports.disaster_type_other. disaster_type_id stays the Other row,
so priority and filters work as before; the screens show the typed name.

Additive only (nullable column, no backfill). Safe to re-run (IF NOT EXISTS).
Reports saved before this revision keep showing "Other".

Revision ID: e2b6d4a8c1f9
Revises: f6a2d9c4b8e1
"""
from alembic import op


revision = "e2b6d4a8c1f9"
down_revision = "f6a2d9c4b8e1"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.execute("ALTER TABLE disaster_reports ADD COLUMN IF NOT EXISTS disaster_type_other VARCHAR(100)")


def downgrade() -> None:
    op.execute("ALTER TABLE disaster_reports DROP COLUMN IF EXISTS disaster_type_other")
