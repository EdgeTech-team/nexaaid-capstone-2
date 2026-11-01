"""Name of the provider when a payment method is "Other" (testing 2.1)

The "Add payment method" form offers GCash, Maya, Bank and Other. Choosing
Other now asks for the provider's own name (for example "Coins.ph"), stored
in provider_other. The existing provider CHECK is not touched: provider stays
one of the four values, provider_other holds the specific name.

Additive only (nullable column, no backfill). Safe to re-run (IF NOT EXISTS).
Rows saved before this revision keep provider = 'Other' with no name.

Revision ID: c5d8f2a7b1e3
Revises: c6d2a8e4f1b7
"""
from alembic import op


revision = "c5d8f2a7b1e3"
down_revision = "c6d2a8e4f1b7"
branch_labels = None
depends_on = None

TABLES = ("barangay_donation_info", "barangay_donation_methods", "report_donation_info")


def upgrade() -> None:
    for t in TABLES:
        op.execute(f"ALTER TABLE {t} ADD COLUMN IF NOT EXISTS provider_other VARCHAR(50)")


def downgrade() -> None:
    for t in TABLES:
        op.execute(f"ALTER TABLE {t} DROP COLUMN IF EXISTS provider_other")