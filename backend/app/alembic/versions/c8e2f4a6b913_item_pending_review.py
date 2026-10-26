"""items.pending_review: items typed in by donors and guests wait for CSWS
Main Office or the Administrator before they appear in any dropdown
(security audit F-15).

Additive with a default: every existing item stays visible. Safe to re-run.

Revision ID: c8e2f4a6b913
Revises: a1f09c3e5d72
"""
from alembic import op


revision = "c8e2f4a6b913"
down_revision = "a1f09c3e5d72"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.execute("ALTER TABLE items ADD COLUMN IF NOT EXISTS pending_review BOOLEAN NOT NULL DEFAULT false")


def downgrade() -> None:
    op.execute("ALTER TABLE items DROP COLUMN IF EXISTS pending_review")
