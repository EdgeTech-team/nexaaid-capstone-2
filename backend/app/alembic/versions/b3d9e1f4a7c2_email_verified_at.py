"""NF-006 (D4): verify the account email once, for Door to Door pickups.

1. users.email_verified_at TIMESTAMPTZ NULL: when the user confirmed their
   email with a code. NULL = not verified.
   Backfill:
   - staff accounts (every role except Individual Donor and Relief
     Organization) are marked verified: the Administrator created them
     with their office email, and they never donate.
   - donor and organization accounts that already have a Door to Door
     donation still waiting are marked verified too, so pickups that are on
     the CSWS map today do not disappear or expire when this is deployed.
     Every other donor and organization verifies once, the first time
     they want a pickup (agreement A4).

2. email_verification_codes: the 6-digit codes (stored hashed), same shape
   as password_reset_tokens (the forgot-password pattern in auth_router).

Safe to re-run (IF NOT EXISTS).

Revision ID: b3d9e1f4a7c2
Revises: e2a7c4d9f5b1
"""
from alembic import op


revision = "b3d9e1f4a7c2"
down_revision = "e2a7c4d9f5b1"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.execute("ALTER TABLE users ADD COLUMN IF NOT EXISTS email_verified_at TIMESTAMP WITH TIME ZONE")
    op.execute(
        """
        UPDATE users SET email_verified_at = COALESCE(created_at, now())
        WHERE email_verified_at IS NULL
          AND role_id IN (SELECT role_id FROM roles
                          WHERE role_name NOT IN ('Individual Donor', 'Relief Organization'))
        """
    )
    op.execute(
        """
        UPDATE users SET email_verified_at = now()
        WHERE email_verified_at IS NULL
          AND user_id IN (SELECT DISTINCT user_id FROM physical_donations
                          WHERE handover_method = 'Door to Door' AND status = 'Pending'
                            AND user_id IS NOT NULL)
        """
    )
    op.execute(
        """
        CREATE TABLE IF NOT EXISTS email_verification_codes (
            code_id SERIAL PRIMARY KEY,
            user_id INTEGER NOT NULL REFERENCES users (user_id) ON DELETE CASCADE,
            code_hash VARCHAR(64) NOT NULL,
            expires_at TIMESTAMP WITH TIME ZONE NOT NULL,
            used_at TIMESTAMP WITH TIME ZONE,
            attempts INTEGER NOT NULL DEFAULT 0,
            created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
        )
        """
    )
    op.execute(
        "CREATE INDEX IF NOT EXISTS ix_email_verification_codes_user_id "
        "ON email_verification_codes (user_id)"
    )


def downgrade() -> None:
    op.execute("DROP TABLE IF EXISTS email_verification_codes")
    op.execute("ALTER TABLE users DROP COLUMN IF EXISTS email_verified_at")
