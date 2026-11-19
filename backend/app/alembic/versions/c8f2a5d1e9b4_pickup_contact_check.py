"""NF-007 (D5): call to confirm every Door to Door pickup stop.

physical_donations gets the result of the confirmation call:
    contact_confirmed_at          TIMESTAMPTZ NULL   when staff called the donor
    contact_confirmed_by_user_id  INT NULL, FK users who called
    contact_outcome               VARCHAR(20) NULL   Reached / No answer / Wrong number

A pickup run cannot be sent while one of its stops has no "Reached" call.
Existing rows start with NULL (not called yet).

Safe to re-run (IF NOT EXISTS).

Revision ID: c8f2a5d1e9b4
Revises: b3d9e1f4a7c2
"""
from alembic import op


revision = "c8f2a5d1e9b4"
down_revision = "b3d9e1f4a7c2"
branch_labels = None
depends_on = None

CHECK = "chk_physical_donations_contact_outcome"
FK = "fk_physical_donations_contact_by"


def upgrade() -> None:
    op.execute("ALTER TABLE physical_donations ADD COLUMN IF NOT EXISTS contact_confirmed_at TIMESTAMP WITH TIME ZONE")
    op.execute("ALTER TABLE physical_donations ADD COLUMN IF NOT EXISTS contact_confirmed_by_user_id INTEGER")
    op.execute("ALTER TABLE physical_donations ADD COLUMN IF NOT EXISTS contact_outcome VARCHAR(20)")
    op.execute(f"ALTER TABLE physical_donations DROP CONSTRAINT IF EXISTS {FK}")
    op.execute(
        f"ALTER TABLE physical_donations ADD CONSTRAINT {FK} FOREIGN KEY "
        "(contact_confirmed_by_user_id) REFERENCES users (user_id) ON DELETE SET NULL"
    )
    op.execute(f"ALTER TABLE physical_donations DROP CONSTRAINT IF EXISTS {CHECK}")
    op.execute(
        f"ALTER TABLE physical_donations ADD CONSTRAINT {CHECK} CHECK "
        "(contact_outcome IS NULL OR contact_outcome IN ('Reached', 'No answer', 'Wrong number'))"
    )


def downgrade() -> None:
    op.execute(f"ALTER TABLE physical_donations DROP CONSTRAINT IF EXISTS {CHECK}")
    op.execute(f"ALTER TABLE physical_donations DROP CONSTRAINT IF EXISTS {FK}")
    op.execute("ALTER TABLE physical_donations DROP COLUMN IF EXISTS contact_outcome")
    op.execute("ALTER TABLE physical_donations DROP COLUMN IF EXISTS contact_confirmed_by_user_id")
    op.execute("ALTER TABLE physical_donations DROP COLUMN IF EXISTS contact_confirmed_at")
