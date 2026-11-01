"""Whose goods went on each delivery (Oct 13 concerns, delivery preparation)

delivery_allocations: for every delivery line, which donations its goods
came from and how much of each (services/delivery_allocation.py: first
received, first sent; CMO-acknowledged donations first). The donor's
timeline (In transit / Delivered / Barangay confirmed) follows these rows.

Existing deliveries are filled in here with the same rule, oldest delivery
first, so donors whose goods already went out see it right away. Cancelled
deliveries get none. Additive only; downgrade drops the table.

Revision ID: c6d2a8e4f1b7
Revises: b4e7c2d9f1a6
"""
import sqlalchemy as sa
from alembic import op


revision = "c6d2a8e4f1b7"
down_revision = "b4e7c2d9f1a6"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.execute(
        """
        CREATE TABLE IF NOT EXISTS delivery_allocations (
            allocation_id SERIAL PRIMARY KEY,
            delivery_item_id INTEGER NOT NULL,
            donation_id INTEGER NOT NULL,
            quantity INTEGER NOT NULL,
            CONSTRAINT chk_delivery_allocations_quantity CHECK (quantity > 0),
            CONSTRAINT fk_delivery_allocations_delivery_item_id FOREIGN KEY (delivery_item_id)
                REFERENCES delivery_items (delivery_item_id) ON DELETE CASCADE,
            CONSTRAINT fk_delivery_allocations_donation_id FOREIGN KEY (donation_id)
                REFERENCES physical_donations (donation_id) ON DELETE CASCADE
        )
        """
    )
    op.execute("CREATE INDEX IF NOT EXISTS ix_delivery_allocations_delivery_item_id ON delivery_allocations (delivery_item_id)")
    op.execute("CREATE INDEX IF NOT EXISTS ix_delivery_allocations_donation_id ON delivery_allocations (donation_id)")

    bind = op.get_bind()
    if bind.execute(sa.text("SELECT 1 FROM delivery_allocations LIMIT 1")).first():
        return  # already filled (re-run)
    left: dict = {}   # (report_id, item_id) -> [[donation_id, qty left], ...] in taking order
    for report_id, item_id, donation_id, qty in bind.execute(sa.text(
        """
        SELECT d.report_id, d.item_id, d.donation_id, g.actual_quantity
        FROM physical_donations d JOIN received_goods g ON g.donation_id = d.donation_id
        WHERE d.status IN ('Received', 'Confirmed')
        ORDER BY (d.status <> 'Confirmed'), g.received_at, d.donation_id
        """
    )):
        left.setdefault((report_id, item_id), []).append([donation_id, qty or 0])
    lines = bind.execute(sa.text(
        """
        SELECT i.delivery_item_id, v.report_id, i.item_id, i.quantity
        FROM delivery_items i JOIN deliveries v ON v.delivery_id = i.delivery_id
        WHERE v.status <> 'Cancelled'
        ORDER BY v.created_at, v.delivery_id, i.delivery_item_id
        """
    )).all()
    for delivery_item_id, report_id, item_id, need in lines:
        for slot in left.get((report_id, item_id), []):
            if need <= 0:
                break
            take = min(slot[1], need)
            if take <= 0:
                continue
            bind.execute(sa.text(
                "INSERT INTO delivery_allocations (delivery_item_id, donation_id, quantity) "
                "VALUES (:i, :d, :q)"), {"i": delivery_item_id, "d": slot[0], "q": take})
            slot[1] -= take
            need -= take


def downgrade() -> None:
    op.execute("DROP TABLE IF EXISTS delivery_allocations")
