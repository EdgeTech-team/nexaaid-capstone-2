"""Merge "kitchen kits" into "Kitchen Set"

Nov 22, 2026: the catalog had two kitchen items, "Kitchen Set" (the one
the report templates use) and "kitchen kits" (typed in on a report). One
kitchen item is kept: Kitchen Set. Report needs, donations, stock and
deliveries of the other move to it (amounts added up per report); an item
with another unit is retired instead, its records kept. What is inside a
kit is a note on the donation line (physical_donations.contents), never a
separate item.

Same merge as the item clean-up (f3b8d1c5a9e7), whose helpers are reused.
The downgrade does nothing (merged rows cannot be told apart again).

Revision ID: b4d8f2a6c0e3
Revises: a9e5c7d3b1f2
"""
import importlib.util
from pathlib import Path
from typing import Sequence, Union

from alembic import op

revision: str = "b4d8f2a6c0e3"
down_revision: Union[str, Sequence[str], None] = "a9e5c7d3b1f2"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None

# Other names of the kitchen item (services/donations/items.py ITEM_ALIASES too).
KITCHEN_NAMES = ("kitchen kit", "kitchen kits", "kitchen sets")


def _cleanup():
    path = next(Path(__file__).parent.glob("f3b8d1c5a9e7_*.py"))
    spec = importlib.util.spec_from_file_location("item_cleanup_f3b8d1c5a9e7", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def upgrade() -> None:
    bind = op.get_bind()
    m = _cleanup()
    for name in KITCHEN_NAMES:
        # Without a "Kitchen Set" yet, the first one is renamed to it.
        m._fold_into(bind, name, "Kitchen Set", rename_when_missing=True)


def downgrade() -> None:
    pass
