"""org address optional

Revision ID: 19496b82cebd
Revises: 6c2c1e3ba995
Create Date: 2026-10-09 17:27:13.210302

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision: str = '19496b82cebd'
down_revision: Union[str, Sequence[str], None] = '6c2c1e3ba995'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.alter_column(
        "organizations",
        "address",
        existing_type=sa.Text(),
        nullable=True,
    )


def downgrade() -> None:
    op.execute("UPDATE organizations SET address = '' WHERE address IS NULL")
    op.alter_column(
        "organizations",
        "address",
        existing_type=sa.Text(),
        nullable=False,
    )