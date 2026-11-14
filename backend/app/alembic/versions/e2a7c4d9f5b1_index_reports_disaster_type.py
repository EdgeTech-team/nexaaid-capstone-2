"""NF-001 (T2): index disaster_reports.disaster_type_id.

The Administrator's records screen now filters every tab (Donations, Per
report, Deliveries, Logistics) by disaster type in the database, through
record -> report -> disaster_type_id. This index keeps that lookup fast as
the number of reports grows.

Index only: no table or column changes, so the data dictionary and the ERD
stay as they are (listed separately per the team's rule 3).

Revision ID: e2a7c4d9f5b1
Revises: e4f1a9c3b7d2
"""
from alembic import op


revision = "e2a7c4d9f5b1"
down_revision = "e4f1a9c3b7d2"
branch_labels = None
depends_on = None

INDEX = "idx_disaster_reports_disaster_type"


def upgrade() -> None:
    op.create_index(INDEX, "disaster_reports", ["disaster_type_id"], unique=False,
                    if_not_exists=True)


def downgrade() -> None:
    op.drop_index(INDEX, table_name="disaster_reports", if_exists=True)
