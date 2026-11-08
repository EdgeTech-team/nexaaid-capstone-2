"""Retire "MC Water" (NF-006, Nov 2026).

CSWS does not receive it, but on Neon (Nov 8) it has 1 received donation
(3,750 L, still in stock for report 16) and 1 pending donation (4,000 L,
report 18), so it is retired instead of deleted, like Drinking Water
(gallons) and Clothing (packs): active = false keeps it out of every
dropdown and need template; old donations stay correct, the stock can
still be delivered and the pending donation can still be received.

Its report needs are deleted (1 row, report 13), so no report waits for an
item nobody can donate. Run scripts/recompute_priorities.py afterwards.

Downgrade makes it active again; the deleted need does not come back.

Revision ID: c7a2d4f8e1b6
Revises: b5e1f7a3c8d2
"""
from alembic import op


revision = "c7a2d4f8e1b6"
down_revision = "b5e1f7a3c8d2"
branch_labels = None
depends_on = None

_MC = "(SELECT item_id FROM items WHERE lower(item_name) = 'mc water')"


def upgrade() -> None:
    op.execute(f"DELETE FROM report_needs WHERE item_id IN {_MC}")
    op.execute("UPDATE items SET active = false WHERE lower(item_name) = 'mc water'")


def downgrade() -> None:
    op.execute("UPDATE items SET active = true WHERE lower(item_name) = 'mc water'")
