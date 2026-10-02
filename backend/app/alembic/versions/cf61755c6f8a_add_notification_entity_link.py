
"""add notification entity link

Revision ID: cf61755c6f8a
Revises: da126cd397f0
Create Date: 2026-10-03 01:21:01.043337

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision: str = 'cf61755c6f8a'
down_revision: Union[str, Sequence[str], None] = 'da126cd397f0'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade():
    op.add_column('notifications', sa.Column('entity_type', sa.String(50), nullable=True))
    op.add_column('notifications', sa.Column('entity_id', sa.Integer(), nullable=True))

def downgrade():
    op.drop_column('notifications', 'entity_id')
    op.drop_column('notifications', 'entity_type')