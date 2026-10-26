"""Items added later to the same donation (Oct 23, Dave; approved by Daniel)

physical_donations.addition_no: which part of a donation an item came with.
1 = the original pledge; 2, 3, ... = items the donor added later to the SAME
donation (same batch_reference, same QR code). Every existing row becomes 1
through the column default, so every donation made before this migration
reads as "Batch 1". The item's own created_at is when it was added, and its
status (Pending / Received / Confirmed ...) was already per item, so no
status or timestamp is copied or rewritten.

Additive: one NOT NULL column with a default, and one index for looking up
a donation's batches. Downgrade drops both. Safe to re-run.

Revision ID: a1d4e7c9b2f5
Revises: f2a9c4e7b1d3
"""
from alembic import op


revision = "a1d4e7c9b2f5"
down_revision = "f2a9c4e7b1d3"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.execute(
        "ALTER TABLE physical_donations "
        "ADD COLUMN IF NOT EXISTS addition_no INTEGER NOT NULL DEFAULT 1"
    )
    op.execute(
        "CREATE INDEX IF NOT EXISTS idx_physical_donations_batch_addition "
        "ON physical_donations (batch_reference, addition_no)"
    )


def downgrade() -> None:
    op.execute("DROP INDEX IF EXISTS idx_physical_donations_batch_addition")
    op.execute("ALTER TABLE physical_donations DROP COLUMN IF EXISTS addition_no")
