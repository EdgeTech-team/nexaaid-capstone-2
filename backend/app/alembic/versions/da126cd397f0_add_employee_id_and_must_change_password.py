"""add employee_id and must_change_password to users (adviser item 3)

Revision ID: da126cd397f0
Revises: 142a5db2006c
Create Date: 2026-10-01

RECONSTRUCTED from the live Neon schema, because the original file was
never committed. Neon already has these changes, so on Neon this file
only restores the history. On a fresh database it creates them.
"""

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = "da126cd397f0"
down_revision: Union[str, Sequence[str], None] = "142a5db2006c"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column("users", sa.Column("employee_id", sa.String(30), nullable=True))
    op.add_column(
        "users",
        sa.Column("must_change_password", sa.Boolean(), nullable=False,
                  server_default=sa.false()),
    )
    op.create_unique_constraint("uq_users_employee_id", "users", ["employee_id"])


def downgrade() -> None:
    op.drop_constraint("uq_users_employee_id", "users", type_="unique")
    op.drop_column("users", "must_change_password")
    op.drop_column("users", "employee_id")
