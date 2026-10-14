"""Withdrawn reports ("Cancelled") and review of individual donor registrations

1. disaster_reports.status may be 'Cancelled' (Oct 11 notes, Daniel: the
   CSWS Disaster Unit withdraws its own report before it is validated; the
   report is kept for the record). Neon has a check constraint
   chk_disaster_reports_status that was never in the migrations and does not
   allow 'Cancelled', so withdrawing failed with a CheckViolation. It is
   recreated here with every value the old constraint allowed, every status
   already in the table, and 'Cancelled'.

2. users.reviewed_at / reviewed_by_user_id: the Administrator reviews
   individual donor registrations too, like organizations
   (organizations.reviewed_at). Review only: the account is active either
   way. Existing donors start as Not Reviewed.

Safe to re-run (IF EXISTS / IF NOT EXISTS).

Revision ID: a7c3e5f19b42
Revises: d8f3a1c6b2e4
"""
import re

import sqlalchemy as sa
from alembic import op


revision = "a7c3e5f19b42"
down_revision = "d8f3a1c6b2e4"
branch_labels = None
depends_on = None

CHECK = "chk_disaster_reports_status"
BASE_STATUSES = ("Pending", "Validated", "Rejected")


def _allowed_now(bind) -> set:
    """Values the current constraint allows, plus statuses already stored."""
    allowed = set(BASE_STATUSES)
    old = bind.execute(
        sa.text("SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname = :n"),
        {"n": CHECK},
    ).scalar()
    if old:
        allowed |= set(re.findall(r"'([^']+)'", old))
    allowed |= {
        s for (s,) in bind.execute(sa.text("SELECT DISTINCT status FROM disaster_reports"))
        if s
    }
    return allowed


def _set_check(values: set, not_valid: bool = False) -> None:
    listed = ", ".join("'" + v.replace("'", "''") + "'" for v in sorted(values))
    op.execute(f"ALTER TABLE disaster_reports DROP CONSTRAINT IF EXISTS {CHECK}")
    op.execute(
        f"ALTER TABLE disaster_reports ADD CONSTRAINT {CHECK} "
        f"CHECK (status IN ({listed})){' NOT VALID' if not_valid else ''}"
    )


def upgrade() -> None:
    bind = op.get_bind()
    _set_check(_allowed_now(bind) | {"Cancelled"})

    op.execute("ALTER TABLE users ADD COLUMN IF NOT EXISTS reviewed_at TIMESTAMP WITH TIME ZONE")
    op.execute("ALTER TABLE users ADD COLUMN IF NOT EXISTS reviewed_by_user_id INTEGER")
    op.execute("ALTER TABLE users DROP CONSTRAINT IF EXISTS fk_users_reviewed_by")
    op.execute(
        "ALTER TABLE users ADD CONSTRAINT fk_users_reviewed_by FOREIGN KEY "
        "(reviewed_by_user_id) REFERENCES users (user_id) ON DELETE SET NULL"
    )


def downgrade() -> None:
    op.execute("ALTER TABLE users DROP CONSTRAINT IF EXISTS fk_users_reviewed_by")
    op.execute("ALTER TABLE users DROP COLUMN IF EXISTS reviewed_by_user_id")
    op.execute("ALTER TABLE users DROP COLUMN IF EXISTS reviewed_at")

    # Withdrawn reports stay in the table, so the narrower rule is only
    # checked for new rows (NOT VALID).
    bind = op.get_bind()
    _set_check(_allowed_now(bind) - {"Cancelled"}, not_valid=True)
