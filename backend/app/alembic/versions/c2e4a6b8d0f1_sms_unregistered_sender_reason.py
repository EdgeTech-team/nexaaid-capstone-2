"""Unregistered SMS sender reason (J8 / NF-014, team agreement Nov 18, 2026, A5)

sms_report_metadata
  unregistered_sender_reason  why the Administrator encoded an SMS whose
                              sender number matches no active CSWS Disaster
                              Unit member (NULL = a registered sender). The
                              report shows it as a warning until validated.

Additive only; downgrade drops the column.

Revision ID: c2e4a6b8d0f1
Revises: b9d1f3a5c7e2
"""
from alembic import op


revision = "c2e4a6b8d0f1"
down_revision = "b9d1f3a5c7e2"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.execute(
        "ALTER TABLE sms_report_metadata ADD COLUMN IF NOT EXISTS unregistered_sender_reason TEXT"
    )


def downgrade() -> None:
    op.execute("ALTER TABLE sms_report_metadata DROP COLUMN IF EXISTS unregistered_sender_reason")
