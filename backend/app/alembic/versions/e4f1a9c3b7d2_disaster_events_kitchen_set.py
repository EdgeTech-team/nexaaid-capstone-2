"""Multi-barangay disaster events (NF-003) and the Kitchen Set item (Nov 2026).

1. disaster_events: one disaster that hit several barangays ("Earthquake -
   Nov 9, 2026"). The CSWS Disaster Unit fills in one form for all of them;
   the system still saves ONE disaster report per barangay and links them
   with the new disaster_reports.event_id (NULL = single-barangay report).
   Each report keeps its own families, needs, validation, priority,
   deliveries and fulfillment.
2. Kitchen Set (category Kitchen, unit sets): CSWS receives and releases
   kitchen sets (UAT post-meeting, Nov 2026). Added only when missing.

Downgrade drops the column and the table, and deletes Kitchen Set only when
nothing uses it.

Revision ID: e4f1a9c3b7d2
Revises: d9e3b7a1c5f2
"""
import sqlalchemy as sa
from alembic import op


revision = "e4f1a9c3b7d2"
down_revision = "d9e3b7a1c5f2"
branch_labels = None
depends_on = None

KITCHEN_SET = "Kitchen Set"


def upgrade() -> None:
    op.create_table(
        "disaster_events",
        sa.Column("event_id", sa.Integer(), primary_key=True, autoincrement=True),
        sa.Column("event_name", sa.String(150), nullable=False),
        sa.Column("disaster_type_id", sa.Integer(), nullable=False),
        sa.Column("disaster_type_other", sa.String(100), nullable=True),
        sa.Column("created_by_user_id", sa.Integer(), nullable=False),
        sa.Column("created_at", sa.TIMESTAMP(timezone=True), nullable=False,
                  server_default=sa.func.now()),
        sa.ForeignKeyConstraint(["disaster_type_id"], ["disaster_types.disaster_type_id"],
                                name="fk_disaster_events_disaster_type_id", ondelete="RESTRICT"),
        sa.ForeignKeyConstraint(["created_by_user_id"], ["users.user_id"],
                                name="fk_disaster_events_created_by_user_id", ondelete="RESTRICT"),
    )
    op.add_column("disaster_reports", sa.Column("event_id", sa.Integer(), nullable=True))
    op.create_foreign_key(
        "fk_disaster_reports_event_id", "disaster_reports", "disaster_events",
        ["event_id"], ["event_id"], ondelete="SET NULL",
    )
    op.create_index("ix_disaster_reports_event_id", "disaster_reports", ["event_id"])

    op.execute(sa.text(
        "INSERT INTO items (item_name, category, unit_of_measure) "
        "SELECT :name, 'Kitchen', 'sets' "
        "WHERE NOT EXISTS (SELECT 1 FROM items WHERE lower(item_name) = lower(:name))"
    ).bindparams(name=KITCHEN_SET))


def downgrade() -> None:
    unused = " AND ".join(
        f"NOT EXISTS (SELECT 1 FROM {table} x WHERE x.item_id = i.item_id)"
        for table in ("report_needs", "physical_donations", "inventory", "delivery_items"))
    op.execute(sa.text(
        f"DELETE FROM items i WHERE i.item_name = :name AND {unused}"
    ).bindparams(name=KITCHEN_SET))

    op.drop_index("ix_disaster_reports_event_id", table_name="disaster_reports")
    op.drop_constraint("fk_disaster_reports_event_id", "disaster_reports", type_="foreignkey")
    op.drop_column("disaster_reports", "event_id")
    op.drop_table("disaster_events")
