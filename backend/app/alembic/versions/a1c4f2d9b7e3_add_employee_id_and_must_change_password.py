"""add employee_id and must_change_password to users

Revision ID: a1c4f2d9b7e3
Revises: 7ebb7eafb3fe
"""
from typing import Sequence, Union
from alembic import op
import sqlalchemy as sa

revision: str = "a1c4f2d9b7e3"
down_revision: Union[str, Sequence[str], None] = "7ebb7eafb3fe"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column("users", sa.Column("employee_id", sa.String(30), nullable=True))
    op.add_column("users", sa.Column("must_change_password", sa.Boolean(), server_default=sa.text("false"), nullable=False))
    # Postgres allows many NULLs under UNIQUE, so donors/orgs (no employee ID) are fine
    op.create_unique_constraint("uq_users_employee_id", "users", ["employee_id"])


def downgrade() -> None:
    op.drop_constraint("uq_users_employee_id", "users", type_="unique")
    op.drop_column("users", "must_change_password")
    op.drop_column("users", "employee_id")