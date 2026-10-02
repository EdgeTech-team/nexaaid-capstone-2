"""merge registration security and organization migrations

Revision ID: da126cd397f0
Revises: 142a5db2006c, a1c4f2d9b7e3
Create Date: 2026-10-02 02:10:27.634420

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision: str = 'da126cd397f0'
down_revision: Union[str, Sequence[str], None] = ('142a5db2006c', 'a1c4f2d9b7e3')
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    """Upgrade schema."""
    pass


def downgrade() -> None:
    """Downgrade schema."""
    pass
