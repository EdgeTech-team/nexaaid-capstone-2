"""deliveries: can be cancelled, with a reason (unexpected problems)

When a delivery cannot go ahead (no truck, road closed, barangay not ready),
CSWS cancels it instead of leaving it stuck in Preparing. The goods go back
to the report's stock and the record is kept with the reason.

Additive: one new allowed status ('Cancelled') and two nullable columns.
Written with IF EXISTS / IF NOT EXISTS so it is safe to run even if a
teammate's migration already touched the same table.

Revision ID: 9c4e2b7a1f35
Revises: c4a91f27d3b8 (teammate's migration, already on Neon)
"""
from alembic import op


revision = "9c4e2b7a1f35"
down_revision = "c4a91f27d3b8"
branch_labels = None
depends_on = None

OLD = "status IN ('Preparing','In Transit','Delivered', 'Confirmed')"
NEW = "status IN ('Preparing','In Transit','Delivered', 'Confirmed', 'Cancelled')"


def upgrade() -> None:
    op.execute("ALTER TABLE deliveries ADD COLUMN IF NOT EXISTS cancelled_at TIMESTAMP WITH TIME ZONE")
    op.execute("ALTER TABLE deliveries ADD COLUMN IF NOT EXISTS cancel_reason TEXT")
    op.execute("ALTER TABLE deliveries DROP CONSTRAINT IF EXISTS deliveries_status_check")
    op.execute(f"ALTER TABLE deliveries ADD CONSTRAINT deliveries_status_check CHECK ({NEW})")


def downgrade() -> None:
    # Cancelled deliveries have no goods out any more; keep their rows as
    # Preparing so the old rule accepts them.
    op.execute("UPDATE deliveries SET status = 'Preparing' WHERE status = 'Cancelled'")
    op.execute("ALTER TABLE deliveries DROP CONSTRAINT IF EXISTS deliveries_status_check")
    op.execute(f"ALTER TABLE deliveries ADD CONSTRAINT deliveries_status_check CHECK ({OLD})")
    op.execute("ALTER TABLE deliveries DROP COLUMN IF EXISTS cancel_reason")
    op.execute("ALTER TABLE deliveries DROP COLUMN IF EXISTS cancelled_at")