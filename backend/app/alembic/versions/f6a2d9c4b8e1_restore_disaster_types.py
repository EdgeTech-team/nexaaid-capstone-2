"""Bring back the disaster types removed in d3f8b2a61c47, except Volcanic Eruption (Oct 2026).

The report form's dropdown (GET /lookups, disaster_types) goes back to every
type it had before d3f8b2a61c47 except Volcanic Eruption, and keeps Other:
Typhoon, Flood, Flash Flood, Storm Surge, Earthquake, Fire, Landslide,
Tsunami, Drought, Disease Outbreak and Other. Only the rows change.

1. Flash Flood, Landslide, Drought and Disease Outbreak are added with their
   old descriptions, or their description updated (ON CONFLICT (type_name)).
   Flood gets its old description back, since Flash Flood is its own type
   again.
2. Volcanic Eruption stays out: d3f8b2a61c47 already moved its reports to
   Other and deleted it.
3. Reports that d3f8b2a61c47 moved to Flood or Other stay there: which ones
   moved is not recorded. Change their type by hand if needed, then run
   scripts/recompute_priorities.py (dry run first).

Downgrade puts back Flood's d3f8b2a61c47 description and deletes the four
types, but only the ones no report uses (disaster_reports.disaster_type_id
is ON DELETE RESTRICT).

Revision ID: f6a2d9c4b8e1
Revises: d3f8b2a61c47
"""
import sqlalchemy as sa
from alembic import op


revision = "f6a2d9c4b8e1"
down_revision = "d3f8b2a61c47"
branch_labels = None
depends_on = None

TYPES = {
    "Flood": "Rising water from heavy rain or overflowing rivers",
    "Flash Flood": "Sudden flooding within hours of heavy rain",
    "Landslide": "Soil or rock sliding down slopes",
    "Drought": "Long dry spell affecting water and food supply",
    "Disease Outbreak": "Epidemic needing medical and hygiene supplies",
}

# Flood's description in d3f8b2a61c47.
MANDAUE_FLOOD = "Urban flooding, flash flood, or river overflow"

_UNUSED = ("NOT EXISTS (SELECT 1 FROM disaster_reports r "
           "WHERE r.disaster_type_id = t.disaster_type_id)")


def _upsert(types: dict) -> None:
    for name, description in types.items():
        op.execute(sa.text(
            "INSERT INTO disaster_types (type_name, description) VALUES (:name, :description) "
            "ON CONFLICT (type_name) DO UPDATE SET description = EXCLUDED.description"
        ).bindparams(name=name, description=description))


def upgrade() -> None:
    _upsert(TYPES)


def downgrade() -> None:
    _upsert({"Flood": MANDAUE_FLOOD})
    added = ", ".join(f"'{name}'" for name in TYPES if name != "Flood")  # constants above
    op.execute(f"DELETE FROM disaster_types t WHERE t.type_name IN ({added}) AND {_UNUSED}")
