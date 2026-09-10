"""add validation audit fields

Revision ID: 7ebb7eafb3fe
Revises: e837b545b195
Create Date: 2026-09-04 09:50:16.988390

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision: str = '7ebb7eafb3fe'
down_revision: Union[str, Sequence[str], None] = 'e837b545b195'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    """Upgrade schema."""
    op.add_column(
        "disaster_reports", sa.Column (
            "validated_by", sa.Integer(), 
            sa.ForeignKey("users.user_id", ondelete="SET NULL"), nullable=True,
        ),
    )

    op.add_column(
        "disaster_reports", sa.Column("rejection_reason", sa.Text(), nullable=True),

    )

def downgrade() -> None:
    """Downgrade schema."""
    op.drop_column("disaster_reports", "rejection_reason")
    op.drop_column("disaster_reports", "validated_by")

