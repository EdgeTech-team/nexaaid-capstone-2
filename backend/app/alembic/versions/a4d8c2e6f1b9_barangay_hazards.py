"""Barangay hazard mapping (NF-004, Nov 2026).

When the Disaster Unit picks a location-specific disaster type, the report
form lists the barangays known to be prone to it first, with a
"Prone to <type>" tag. Any other barangay can still be picked after a
confirm dialog: a soft warning only, the server never blocks a barangay.

1. disaster_types.is_location_specific BOOLEAN NOT NULL DEFAULT FALSE.
   Landslide and Storm Surge are set to true. Every other type (Typhoon,
   Flood, Earthquake, Fire, ...) stays general: all 27 barangays, no warning.
   Flood is general because Typhoon Tino flooded every Mandaue barangay.
2. New table barangay_hazards, UNIQUE (barangay_id, disaster_type_id).
3. Rows from HAZARDS and PENDING_HAZARDS below, matched by name. A name
   that is missing is skipped and an existing pair is kept (ON CONFLICT),
   so it is safe to re-run.

Downgrade drops the table and the column.

Revision ID: a4d8c2e6f1b9
Revises: e1c7a4b9d352
"""
import sqlalchemy as sa
from alembic import op


revision = "a4d8c2e6f1b9"
down_revision = "e1c7a4b9d352"
branch_labels = None
depends_on = None

SOURCE = "Mandaue CDRRMO public statements / city barangay map"

LOCATION_SPECIFIC = ("Landslide", "Storm Surge")

# Confirmed. Names exactly as in the barangays table.
HAZARDS = {
    "Landslide": ["Casili", "Tawason", "Cubacub", "Tingub"],
    "Storm Surge": ["Paknaan", "Umapad", "Opao", "Looc"],
}

# PENDING CDRRMO confirmation. Edit this list once CDRRMO answers; to
# remove a barangay that is already seeded, delete its barangay_hazards row.
PENDING_HAZARDS = {
    "Storm Surge": ["Subangdaku", "Tipolo", "Centro", "Labogon"],
}


def _seed(hazards: dict) -> None:
    for type_name, barangays in hazards.items():
        for barangay in barangays:
            op.execute(sa.text(
                "INSERT INTO barangay_hazards (barangay_id, disaster_type_id, source) "
                "SELECT b.barangay_id, t.disaster_type_id, :source "
                "FROM barangays b JOIN disaster_types t ON t.type_name = :type_name "
                "WHERE b.barangay_name = :barangay "
                "ON CONFLICT (barangay_id, disaster_type_id) DO NOTHING"
            ).bindparams(source=SOURCE, type_name=type_name, barangay=barangay))


def upgrade() -> None:
    op.add_column("disaster_types", sa.Column(
        "is_location_specific", sa.Boolean(), nullable=False, server_default=sa.false()))
    names = ", ".join(f"'{n}'" for n in LOCATION_SPECIFIC)  # constants above, no quotes in them
    op.execute(f"UPDATE disaster_types SET is_location_specific = true WHERE type_name IN ({names})")

    op.create_table(
        "barangay_hazards",
        sa.Column("barangay_hazard_id", sa.Integer(), primary_key=True),
        sa.Column("barangay_id", sa.Integer(),
                  sa.ForeignKey("barangays.barangay_id", ondelete="CASCADE"), nullable=False),
        sa.Column("disaster_type_id", sa.Integer(),
                  sa.ForeignKey("disaster_types.disaster_type_id", ondelete="CASCADE"),
                  nullable=False),
        sa.Column("source", sa.String(150), nullable=True),
        sa.UniqueConstraint("barangay_id", "disaster_type_id",
                            name="uq_barangay_hazards_barangay_type"),
    )
    op.create_index("idx_barangay_hazards_type", "barangay_hazards", ["disaster_type_id"])

    _seed(HAZARDS)
    _seed(PENDING_HAZARDS)


def downgrade() -> None:
    op.drop_index("idx_barangay_hazards_type", table_name="barangay_hazards")
    op.drop_table("barangay_hazards")
    op.drop_column("disaster_types", "is_location_specific")
