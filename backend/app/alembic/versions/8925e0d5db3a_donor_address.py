"""donor address

Revision ID: 8925e0d5db3a
Revises: 19496b82cebd
Create Date: 2026-10-09 17:50:20.458236

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision: str = '8925e0d5db3a'
down_revision: Union[str, Sequence[str], None] = '19496b82cebd'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column("users", sa.Column("address", sa.Text(), nullable=True))


def downgrade() -> None:
    op.drop_column("users", "address")
