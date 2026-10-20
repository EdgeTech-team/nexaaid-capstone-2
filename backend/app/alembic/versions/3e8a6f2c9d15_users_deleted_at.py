"""users.deleted_at: the Administrator can delete a deactivated account
(Appendix H 1.2, testing feedback Oct 2026)

A deleted account's email (and username) must be free to register again.
A real DELETE is impossible once the account has reports, deliveries,
receipts or logistics requests (those foreign keys are RESTRICT), and those
records must stay for transparency. So DELETE /admin/users/{id} anonymizes
the row instead and stamps deleted_at (services/accounts.py).

Additive and nullable: existing rows and every existing query are
unaffected. Safe to re-run.

Revision ID: 3e8a6f2c9d15
Revises: 9b3f7c1d2e48
"""
from alembic import op


revision = "3e8a6f2c9d15"
down_revision = "9b3f7c1d2e48"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.execute("ALTER TABLE users ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMP WITH TIME ZONE")


def downgrade() -> None:
    op.execute("ALTER TABLE users DROP COLUMN IF EXISTS deleted_at")
