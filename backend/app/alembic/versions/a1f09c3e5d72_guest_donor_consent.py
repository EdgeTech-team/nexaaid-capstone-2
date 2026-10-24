"""guest_donors.consent_at: when a guest donor agreed to the processing of
their personal data (security audit F-09, RA 10173).

Additive and nullable: guest donors saved before this have NULL (no consent
was asked then). Every existing query is unaffected. Safe to re-run.

Revision ID: a1f09c3e5d72
Revises: 7f4d2b9e6a31
"""
from alembic import op


revision = "a1f09c3e5d72"
down_revision = "7f4d2b9e6a31"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.execute("ALTER TABLE guest_donors ADD COLUMN IF NOT EXISTS consent_at TIMESTAMP WITH TIME ZONE")


def downgrade() -> None:
    op.execute("ALTER TABLE guest_donors DROP COLUMN IF EXISTS consent_at")
