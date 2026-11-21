"""donation lines: contents of a kit (a note)

Nov 22, 2026: a donor can say what is inside a kit or set, e.g. "Spoon,
Fork, Plate" for a Kitchen Set. One optional text column; the item stays the
kit, so fulfillment, inventory and the report needs do not change.

Revision ID: a9e5c7d3b1f2
Revises: f3b8d1c5a9e7
"""
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = "a9e5c7d3b1f2"
down_revision: Union[str, Sequence[str], None] = "f3b8d1c5a9e7"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column("physical_donations", sa.Column("contents", sa.String(300), nullable=True))


def downgrade() -> None:
    op.drop_column("physical_donations", "contents")
