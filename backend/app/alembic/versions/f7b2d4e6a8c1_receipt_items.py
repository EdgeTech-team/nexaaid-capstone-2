"""Barangay counts each item at receipt (J1 / NF-009, team agreement Nov 18, 2026)

receipt_items: one row per delivery line, saved when the Barangay
Receiving Representative confirms receipt. expected_quantity is what CSWS
sent (delivery_items.quantity), received_quantity is what the barangay
counted. A line that differs needs a reason: "Over" when more arrived;
"Short", "Damaged" or "Wrong item" when fewer arrived; none when equal.

Business rule (services/fulfillment.py): a confirmed line counts as
delivered = min(received_quantity, expected_quantity). Receipts saved
before this migration have no rows here and keep the sent quantity.
Nothing is backfilled. Additive only; downgrade drops the table.

Revision ID: f7b2d4e6a8c1
Revises: e2a7c4d9f5b1
"""
from alembic import op


revision = "f7b2d4e6a8c1"
down_revision = "e2a7c4d9f5b1"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.execute(
        """
        CREATE TABLE IF NOT EXISTS receipt_items (
            receipt_item_id SERIAL PRIMARY KEY,
            receipt_id INTEGER NOT NULL,
            delivery_item_id INTEGER NOT NULL,
            expected_quantity INTEGER NOT NULL,
            received_quantity INTEGER NOT NULL,
            discrepancy_reason VARCHAR(20),
            discrepancy_note TEXT,
            CONSTRAINT fk_receipt_items_receipt_id FOREIGN KEY (receipt_id)
                REFERENCES receipts (receipt_id) ON DELETE CASCADE,
            CONSTRAINT fk_receipt_items_delivery_item_id FOREIGN KEY (delivery_item_id)
                REFERENCES delivery_items (delivery_item_id) ON DELETE CASCADE,
            CONSTRAINT uq_receipt_items_delivery_item_id UNIQUE (delivery_item_id),
            CONSTRAINT chk_receipt_items_expected CHECK (expected_quantity > 0),
            CONSTRAINT chk_receipt_items_received CHECK (received_quantity >= 0),
            CONSTRAINT chk_receipt_items_reason CHECK (
                discrepancy_reason IS NULL
                OR discrepancy_reason IN ('Short', 'Damaged', 'Wrong item', 'Over')),
            CONSTRAINT chk_receipt_items_reason_fits CHECK (
                (received_quantity = expected_quantity AND discrepancy_reason IS NULL)
                OR (received_quantity > expected_quantity
                    AND COALESCE(discrepancy_reason, '') = 'Over')
                OR (received_quantity < expected_quantity
                    AND COALESCE(discrepancy_reason, '') IN ('Short', 'Damaged', 'Wrong item')))
        )
        """
    )
    op.execute("CREATE INDEX IF NOT EXISTS ix_receipt_items_receipt_id ON receipt_items (receipt_id)")


def downgrade() -> None:
    op.execute("DROP TABLE IF EXISTS receipt_items")
