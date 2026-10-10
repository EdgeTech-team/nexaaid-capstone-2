"""separate pickup notes from pickup landmark

Revision ID: c4a91f27d3b8
Revises: 8925e0d5db3a
Create Date: 2026-10-10

Until now the donor's "Notes for the pickup team" were stored in
physical_donations.pickup_landmark. That column now holds the real landmark
(the suggestion the donor picked), and the notes get their own column.
Existing rows hold notes, so they are moved over.
"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


revision: str = 'c4a91f27d3b8'
down_revision: Union[str, Sequence[str], None] = ('8925e0d5db3a', '7a2c4e6b8d10')
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column(
        "physical_donations",
        sa.Column("pickup_notes", sa.Text(), nullable=True),
    )
    # Every existing pickup_landmark value is a note typed by the donor.
    op.execute(
        "UPDATE physical_donations "
        "SET pickup_notes = pickup_landmark, pickup_landmark = NULL "
        "WHERE pickup_landmark IS NOT NULL"
    )


def downgrade() -> None:
    # Put the notes back where the old code expects them.
    op.execute(
        "UPDATE physical_donations "
        "SET pickup_landmark = pickup_notes "
        "WHERE pickup_notes IS NOT NULL"
    )
    op.drop_column("physical_donations", "pickup_notes")