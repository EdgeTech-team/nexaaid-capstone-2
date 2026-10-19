"""Soft delete for disaster reports (testing 2.3)

The Administrator can delete a Rejected report. A hard delete would also
remove its audit trail (who rejected it and why) and break anything that
points at it, so the row is kept and marked: deleted_at is set and every
list, count and lookup hides it. deleted_by_user_id records who did it.

The status CHECK (chk_disaster_reports_status) is not touched: a deleted
report keeps status 'Rejected'.

Additive only (nullable columns). Safe to re-run (IF NOT EXISTS).

Revision ID: d6e9a3b8c2f4
Revises: c5d8f2a7b1e3
"""
from alembic import op


revision = "d6e9a3b8c2f4"
down_revision = "c5d8f2a7b1e3"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.execute("ALTER TABLE disaster_reports ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMP WITH TIME ZONE")
    op.execute("ALTER TABLE disaster_reports ADD COLUMN IF NOT EXISTS deleted_by_user_id INTEGER")
    op.execute(
        """
        DO $$
        BEGIN
            IF NOT EXISTS (
                SELECT 1 FROM pg_constraint WHERE conname = 'fk_disaster_reports_deleted_by'
            ) THEN
                ALTER TABLE disaster_reports
                    ADD CONSTRAINT fk_disaster_reports_deleted_by
                    FOREIGN KEY (deleted_by_user_id) REFERENCES users (user_id) ON DELETE SET NULL;
            END IF;
        END $$;
        """
    )


def downgrade() -> None:
    op.execute("ALTER TABLE disaster_reports DROP CONSTRAINT IF EXISTS fk_disaster_reports_deleted_by")
    op.execute("ALTER TABLE disaster_reports DROP COLUMN IF EXISTS deleted_by_user_id")
    op.execute("ALTER TABLE disaster_reports DROP COLUMN IF EXISTS deleted_at")