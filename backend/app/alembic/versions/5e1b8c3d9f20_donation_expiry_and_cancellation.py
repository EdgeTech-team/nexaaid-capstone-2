"""physical donations: expiry and cancellation (termination of donations)

A donation that is never handed over used to stay 'Pending' forever. Now:
  - every Pending item has a deadline (expires_at). Drop Off: 14 days after
    it was submitted. Door to Door: 7 days after the preferred pickup time.
  - past the deadline the system marks it 'Expired'; a donor can also mark
    it 'Cancelled' while it is still Pending.
  - closed rows are never deleted. closed_at / close_reason /
    closed_by_user_id record when, why and who (NULL = the system).
  - reminder_sent_at: the donor is reminded once, 3 days before the deadline.

Additive: five nullable columns, one index, and two new allowed statuses.
Existing statuses keep their meaning.

Existing Pending rows get a deadline at least 7 days after this migration
runs, so nobody's donation expires the moment this is deployed.

Revision ID: 5e1b8c3d9f20
Revises: 4c9e1a7b2d30 (team fixes Oct 5)
"""
from alembic import op
import sqlalchemy as sa


revision = "5e1b8c3d9f20"
down_revision = "4c9e1a7b2d30"
branch_labels = None
depends_on = None

OLD_STATUSES = "status IN ('Pending', 'Received', 'Confirmed')"
NEW_STATUSES = "status IN ('Pending', 'Received', 'Confirmed', 'Expired', 'Cancelled')"


def upgrade() -> None:
    op.add_column("physical_donations", sa.Column("expires_at", sa.DateTime(timezone=True), nullable=True))
    op.add_column("physical_donations", sa.Column("reminder_sent_at", sa.DateTime(timezone=True), nullable=True))
    op.add_column("physical_donations", sa.Column("closed_at", sa.DateTime(timezone=True), nullable=True))
    op.add_column("physical_donations", sa.Column("close_reason", sa.Text(), nullable=True))
    op.add_column("physical_donations", sa.Column("closed_by_user_id", sa.Integer(), nullable=True))
    op.create_foreign_key(
        "fk_physical_donations_closed_by_user_id", "physical_donations", "users",
        ["closed_by_user_id"], ["user_id"], ondelete="SET NULL",
    )
    op.create_index(
        "idx_physical_donations_status_expires", "physical_donations", ["status", "expires_at"],
    )
    op.drop_constraint("chk_physical_donations_status", "physical_donations", type_="check")
    op.create_check_constraint("chk_physical_donations_status", "physical_donations", NEW_STATUSES)

    # Deadlines for donations already waiting (same rule as
    # services/donation_expiry.deadline_for), never earlier than 7 days from now.
    op.execute("""
        UPDATE physical_donations
        SET expires_at = GREATEST(
            CASE
                WHEN handover_method = 'Door to Door' AND preferred_pickup_at IS NOT NULL
                    THEN preferred_pickup_at + INTERVAL '7 days'
                ELSE created_at + INTERVAL '14 days'
            END,
            NOW() + INTERVAL '7 days'
        )
        WHERE status = 'Pending'
    """)


def downgrade() -> None:
    # Closed rows go back to Pending so the old constraint accepts them.
    op.execute("UPDATE physical_donations SET status = 'Pending' WHERE status IN ('Expired', 'Cancelled')")
    op.drop_constraint("chk_physical_donations_status", "physical_donations", type_="check")
    op.create_check_constraint("chk_physical_donations_status", "physical_donations", OLD_STATUSES)
    op.drop_index("idx_physical_donations_status_expires", table_name="physical_donations")
    op.drop_constraint("fk_physical_donations_closed_by_user_id", "physical_donations", type_="foreignkey")
    op.drop_column("physical_donations", "closed_by_user_id")
    op.drop_column("physical_donations", "close_reason")
    op.drop_column("physical_donations", "closed_at")
    op.drop_column("physical_donations", "reminder_sent_at")
    op.drop_column("physical_donations", "expires_at")
