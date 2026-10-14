"""add organization review tracking

Revision ID: 6c2c1e3ba995
Revises: 505ae23afde0
"""

from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


revision: str = "6c2c1e3ba995"
down_revision: Union[str, Sequence[str], None] = "505ae23afde0"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column(
        "organizations",
        sa.Column("reviewed_at", sa.DateTime(timezone=True), nullable=True),
    )
    op.add_column(
        "organizations",
        sa.Column("reviewed_by_user_id", sa.Integer(), nullable=True),
    )
    op.create_foreign_key(
        "fk_org_reviewed_by",
        "organizations",
        "users",
        ["reviewed_by_user_id"],
        ["user_id"],
        ondelete="SET NULL",
    )


def downgrade() -> None:
    op.drop_constraint(
        "fk_org_reviewed_by",
        "organizations",
        type_="foreignkey",
    )
    op.drop_column("organizations", "reviewed_by_user_id")
    op.drop_column("organizations", "reviewed_at")
