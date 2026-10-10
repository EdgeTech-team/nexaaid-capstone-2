"""add deactivation reason to users

Revision ID: 505ae23afde0
Revises: 2ca2543d2df7
Create Date: 2026-10-08

Adds the reason an Administrator gave when deactivating an account, and when
it happened. Both are nullable: accounts deactivated before this existed keep
NULL and the app shows "No reason was recorded".
"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision: str = "505ae23afde0"
down_revision: Union[str, Sequence[str], None] = "2ca2543d2df7"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column("users", sa.Column("deactivation_reason", sa.Text(), nullable=True))
    op.add_column(
        "users",
        sa.Column("deactivated_at", sa.DateTime(timezone=True), nullable=True),
    )


def downgrade() -> None:
    op.drop_column("users", "deactivated_at")
    op.drop_column("users", "deactivation_reason")