"""Minimum stock level per item (CSWS Main Office dashboard redesign)

Nov 23, 2026: the CSWS overview and Inventory page tag an item "Low" when
the office holds less of it (all reports added together) than its minimum,
and list low items first. items.min_stock is that minimum, in the item's
base unit; 0 means no minimum (never Low).

The standard catalog gets a starting minimum, which the developers can
change in the database. Items donors typed in ("Other") start at 0.

Revision ID: d8a2c4e6f0b3
Revises: c6e0a4b8d2f5
"""
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = "d8a2c4e6f0b3"
down_revision: Union[str, Sequence[str], None] = "c6e0a4b8d2f5"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None

# Starting minimums in each item's base unit (demo_seed.sql catalog).
STARTING_MINIMUMS = {
    "Rice": 100,            # kg
    "Drinking Water": 200,  # L
    "Canned Goods": 100,    # cans
    "Noodles": 100,         # packs
    "Hygiene Kit": 30,      # kits
    "Blanket": 30,          # pcs
    "Sleeping Mat": 30,     # pcs
    "Medicine Kit": 20,     # boxes
    "Clothing": 50,         # pcs
    "Kitchen Set": 10,      # sets
}


def upgrade() -> None:
    op.add_column("items", sa.Column("min_stock", sa.Integer(), nullable=False,
                                     server_default="0"))
    op.create_check_constraint("chk_items_min_stock", "items", "min_stock >= 0")
    bind = op.get_bind()
    for name, minimum in STARTING_MINIMUMS.items():
        bind.execute(sa.text("UPDATE items SET min_stock = :m WHERE lower(item_name) = lower(:n)"),
                     {"m": minimum, "n": name})


def downgrade() -> None:
    op.drop_constraint("chk_items_min_stock", "items", type_="check")
    op.drop_column("items", "min_stock")
