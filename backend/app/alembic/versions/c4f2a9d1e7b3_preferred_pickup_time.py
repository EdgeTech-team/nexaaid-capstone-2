"""physical donations: preferred pickup date and time for Door to Door

UC-D2 alt 7c: a Door to Door donor gives the pickup address and when they
would like CSWS to come. Additive and nullable: Drop Off donations and all
existing rows keep NULL.

Revision ID: c4f2a9d1e7b3
Revises: b7d41c2a9e10 (donation batch and pickup pin)
"""
from alembic import op
import sqlalchemy as sa


revision = "c4f2a9d1e7b3"
down_revision = "b7d41c2a9e10"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column(
        "physical_donations",
        sa.Column("preferred_pickup_at", sa.DateTime(timezone=True), nullable=True),
    )


def downgrade() -> None:
    op.drop_column("physical_donations", "preferred_pickup_at")