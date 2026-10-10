"""Door to Door pickup days; DRRMO support for Disaster Unit pickup runs

1. physical_donations.pickup_days: the days the donor is home for a Door to
   Door pickup, as ISO weekday numbers "1,3,5" (1 = Monday). The app now
   asks for days (Mon / Tue / ...) instead of one date and time, so the
   Disaster Unit can plan pickups by day. preferred_pickup_at stays for the
   entries saved before this change.

2. logistics_requests can now be for a Door to Door pickup run planned by
   the CSWS Disaster Unit on the pickup map, not only for a delivery:
     request_type   'Delivery' (as before) or 'Pickup'
     pickup_date    the day of the pickup run
     pickup_batches the donation entries (QR batch references) to collect,
                    in stop order, comma separated
   delivery_id becomes nullable: a pickup run has no delivery. A check
   keeps every Delivery request tied to a delivery.

Additive and safe to re-run (IF EXISTS / IF NOT EXISTS). Existing rows
become request_type 'Delivery'.

Revision ID: d8f3a1c6b2e4
Revises: 9c4e2b7a1f35
"""
from alembic import op


revision = "d8f3a1c6b2e4"
down_revision = "9c4e2b7a1f35"
branch_labels = None
depends_on = None

TYPE_CHECK = "request_type IN ('Delivery', 'Pickup')"
SHAPE_CHECK = (
    "(request_type = 'Delivery' AND delivery_id IS NOT NULL) OR "
    "(request_type = 'Pickup' AND delivery_id IS NULL AND pickup_date IS NOT NULL)"
)


def upgrade() -> None:
    op.execute("ALTER TABLE physical_donations ADD COLUMN IF NOT EXISTS pickup_days VARCHAR(20)")

    op.execute(
        "ALTER TABLE logistics_requests ADD COLUMN IF NOT EXISTS "
        "request_type VARCHAR(20) DEFAULT 'Delivery' NOT NULL"
    )
    op.execute("ALTER TABLE logistics_requests ADD COLUMN IF NOT EXISTS pickup_date DATE")
    op.execute("ALTER TABLE logistics_requests ADD COLUMN IF NOT EXISTS pickup_batches TEXT")
    op.execute("ALTER TABLE logistics_requests ALTER COLUMN delivery_id DROP NOT NULL")
    op.execute("ALTER TABLE logistics_requests DROP CONSTRAINT IF EXISTS chk_logistics_request_type")
    op.execute(f"ALTER TABLE logistics_requests ADD CONSTRAINT chk_logistics_request_type CHECK ({TYPE_CHECK})")
    op.execute("ALTER TABLE logistics_requests DROP CONSTRAINT IF EXISTS chk_logistics_request_shape")
    op.execute(f"ALTER TABLE logistics_requests ADD CONSTRAINT chk_logistics_request_shape CHECK ({SHAPE_CHECK})")


def downgrade() -> None:
    # Pickup-run requests have no delivery, so the old NOT NULL rule cannot
    # keep them. They are removed (their history stays in the audit log).
    op.execute("DELETE FROM logistics_requests WHERE request_type = 'Pickup'")
    op.execute("ALTER TABLE logistics_requests DROP CONSTRAINT IF EXISTS chk_logistics_request_shape")
    op.execute("ALTER TABLE logistics_requests DROP CONSTRAINT IF EXISTS chk_logistics_request_type")
    op.execute("ALTER TABLE logistics_requests ALTER COLUMN delivery_id SET NOT NULL")
    op.execute("ALTER TABLE logistics_requests DROP COLUMN IF EXISTS pickup_batches")
    op.execute("ALTER TABLE logistics_requests DROP COLUMN IF EXISTS pickup_date")
    op.execute("ALTER TABLE logistics_requests DROP COLUMN IF EXISTS request_type")

    op.execute("ALTER TABLE physical_donations DROP COLUMN IF EXISTS pickup_days")
