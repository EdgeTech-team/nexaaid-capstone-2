"""CSWS shortfall review (J5 / NF-010, team agreement Nov 18, 2026, A3)

deliveries
  discrepancy_cause                why a Confirmed delivery came up short, as
                                   CSWS Main Office found it: Damaged, Lost in
                                   transit, Miscount at office or Miscount at
                                   barangay (NULL = not reviewed yet)
  discrepancy_note                 optional note by the reviewer
  discrepancy_reviewed_at          when it was (last) reviewed
  discrepancy_reviewed_by_user_id  who reviewed it (users.user_id)

A review changes no stock, fulfillment or priority: office miscounts are
fixed with the existing inventory adjustment. Re-reviewing replaces these
columns; the audit log keeps every review. Additive only; downgrade drops
the columns.

Revision ID: b9d1f3a5c7e2
Revises: a8c3e5f7b9d1
"""
from alembic import op


revision = "b9d1f3a5c7e2"
down_revision = "a8c3e5f7b9d1"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.execute("ALTER TABLE deliveries ADD COLUMN IF NOT EXISTS discrepancy_cause VARCHAR(30)")
    op.execute("ALTER TABLE deliveries ADD COLUMN IF NOT EXISTS discrepancy_note TEXT")
    op.execute("ALTER TABLE deliveries ADD COLUMN IF NOT EXISTS discrepancy_reviewed_at TIMESTAMPTZ")
    op.execute("ALTER TABLE deliveries ADD COLUMN IF NOT EXISTS discrepancy_reviewed_by_user_id INTEGER")
    op.execute(
        """
        DO $$
        BEGIN
            IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fk_deliveries_discrepancy_reviewed_by') THEN
                ALTER TABLE deliveries ADD CONSTRAINT fk_deliveries_discrepancy_reviewed_by
                    FOREIGN KEY (discrepancy_reviewed_by_user_id) REFERENCES users (user_id) ON DELETE SET NULL;
            END IF;
            IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'chk_deliveries_discrepancy_cause') THEN
                ALTER TABLE deliveries ADD CONSTRAINT chk_deliveries_discrepancy_cause CHECK (
                    discrepancy_cause IS NULL
                    OR discrepancy_cause IN ('Damaged', 'Lost in transit',
                                             'Miscount at office', 'Miscount at barangay'));
            END IF;
        END
        $$;
        """
    )


def downgrade() -> None:
    op.execute("ALTER TABLE deliveries DROP CONSTRAINT IF EXISTS chk_deliveries_discrepancy_cause")
    op.execute("ALTER TABLE deliveries DROP CONSTRAINT IF EXISTS fk_deliveries_discrepancy_reviewed_by")
    op.execute("ALTER TABLE deliveries DROP COLUMN IF EXISTS discrepancy_reviewed_by_user_id")
    op.execute("ALTER TABLE deliveries DROP COLUMN IF EXISTS discrepancy_reviewed_at")
    op.execute("ALTER TABLE deliveries DROP COLUMN IF EXISTS discrepancy_note")
    op.execute("ALTER TABLE deliveries DROP COLUMN IF EXISTS discrepancy_cause")
