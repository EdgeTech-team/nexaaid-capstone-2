"""org review fields and addresses (stand-in for a teammate's unpushed migration)

This revision was applied to Neon on or before Oct 9, 2026 from a laptop,
but the file was never pushed. It is re-created here so Alembic can find
its place on Neon. What it added, read from Neon itself:
  - organizations.reviewed_at, organizations.reviewed_by_user_id
  - users.address
  - organizations.address made optional

On Neon these already exist, so this file never runs there (Neon is already
at this revision). On a new database it adds them, skipping anything that
already exists.

When the teammate pushes the real 8925e0d5db3a file, keep ONE of the two
(same revision id). If they differ, keep theirs.

Revision ID: 8925e0d5db3a
Revises: 505ae23afde0 (deactivation reason)
"""
from alembic import op


revision = "8925e0d5db3a"
down_revision = "505ae23afde0"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.execute("ALTER TABLE organizations ADD COLUMN IF NOT EXISTS reviewed_at TIMESTAMP WITH TIME ZONE")
    op.execute(
        "ALTER TABLE organizations ADD COLUMN IF NOT EXISTS reviewed_by_user_id INTEGER "
        "REFERENCES users (user_id) ON DELETE SET NULL"
    )
    op.execute("ALTER TABLE users ADD COLUMN IF NOT EXISTS address TEXT")
    op.execute("ALTER TABLE organizations ALTER COLUMN address DROP NOT NULL")


def downgrade() -> None:
    op.execute("ALTER TABLE users DROP COLUMN IF EXISTS address")
    op.execute("ALTER TABLE organizations DROP COLUMN IF EXISTS reviewed_by_user_id")
    op.execute("ALTER TABLE organizations DROP COLUMN IF EXISTS reviewed_at")
    # organizations.address stays optional: making it required again could
    # fail on rows saved without one.