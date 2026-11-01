"""Soft delete for deliveries (testing, Oct 27)

CSWS Main Office can delete a Cancelled or Confirmed delivery from the
delivery list. A Confirmed delivery's quantities are the official
fulfillment figure and its receipt is the barangay's record, so the row is
kept and marked: deleted_at is set and the delivery lists and counts hide
it. deleted_by_user_id records who did it.

Additive only (nullable columns). Safe to re-run (IF NOT EXISTS).

Revision ID: b7d3e9f1a2c4
Revises: c8e2f4a6b913
"""
from alembic import op


revision = "b7d3e9f1a2c4"
down_revision = "c8e2f4a6b913"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.execute("ALTER TABLE deliveries ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMP WITH TIME ZONE")
    op.execute("ALTER TABLE deliveries ADD COLUMN IF NOT EXISTS deleted_by_user_id INTEGER")
    op.execute(
        """
        DO $$
        BEGIN
            IF NOT EXISTS (
                SELECT 1 FROM pg_constraint WHERE conname = 'fk_deliveries_deleted_by'
            ) THEN
                ALTER TABLE deliveries
                    ADD CONSTRAINT fk_deliveries_deleted_by
                    FOREIGN KEY (deleted_by_user_id) REFERENCES users (user_id) ON DELETE SET NULL;
            END IF;
        END $$;
        """
    )


def downgrade() -> None:
    op.execute("ALTER TABLE deliveries DROP CONSTRAINT IF EXISTS fk_deliveries_deleted_by")
    op.execute("ALTER TABLE deliveries DROP COLUMN IF EXISTS deleted_by_user_id")
    op.execute("ALTER TABLE deliveries DROP COLUMN IF EXISTS deleted_at")
