"""Disaster types for Mandaue City (Oct 2026).

The report form's dropdown (GET /lookups, disaster_types) now offers the
seven types that happen in Mandaue City: Typhoon, Flood, Storm Surge,
Earthquake, Fire, Tsunami and Other. Only the rows change; the table stays
as in the manuscript's data dictionary.

1. The seven types are added, or their description updated
   (ON CONFLICT (type_name)), so it is safe on a database that already has
   some of them.
2. Reports of a type that is going away move to the closest new one:
   Flash Flood -> Flood; Landslide, Volcanic Eruption, Drought and
   Disease Outbreak -> Other. Their priority is NOT recomputed here: run
   scripts/recompute_priorities.py afterwards (dry run first).
3. Every type not on the list is deleted, but only when no report uses it
   (disaster_reports.disaster_type_id is ON DELETE RESTRICT).

Downgrade restores the old descriptions and the removed types (they get
new ids), and removes Other only when no report uses it. Reports moved in
step 2 stay on their new type: which ones moved is not recorded.

Revision ID: d3f8b2a61c47
Revises: b7d3e9f1a2c4
"""
import sqlalchemy as sa
from alembic import op


revision = "d3f8b2a61c47"
down_revision = "b7d3e9f1a2c4"
branch_labels = None
depends_on = None

TYPES = {
    "Typhoon": "Tropical cyclone with strong winds and heavy rain",
    "Flood": "Urban flooding, flash flood, or river overflow",
    "Storm Surge": "Coastal flooding caused by a typhoon's storm surge",
    "Earthquake": "Ground shaking from a seismic event, including damage from aftershocks",
    "Fire": "Residential, commercial, or industrial fire",
    "Tsunami": "Coastal flooding caused by a seismic event",
    "Other": "Disaster not covered by the listed types; details go in the report description",
}

REMAP = {
    "Flash Flood": "Flood",
    "Landslide": "Other",
    "Volcanic Eruption": "Other",
    "Drought": "Other",
    "Disease Outbreak": "Other",
}

# The types and descriptions before this migration (database/seeds/demo_seed.sql).
OLD_TYPES = {
    "Flood": "Rising water from heavy rain or overflowing rivers",
    "Flash Flood": "Sudden flooding within hours of heavy rain",
    "Typhoon": "Tropical cyclone with strong winds and heavy rain",
    "Storm Surge": "Coastal flooding pushed in by a typhoon",
    "Fire": "Residential or commercial fire",
    "Earthquake": "Ground shaking and structural damage",
    "Landslide": "Soil or rock sliding down slopes",
    "Tsunami": "Sea waves caused by an undersea earthquake",
    "Volcanic Eruption": "Ashfall or eruption affecting the area",
    "Drought": "Long dry spell affecting water and food supply",
    "Disease Outbreak": "Epidemic needing medical and hygiene supplies",
}

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
    for old, new in REMAP.items():
        op.execute(sa.text(
            "UPDATE disaster_reports SET disaster_type_id = "
            "(SELECT disaster_type_id FROM disaster_types WHERE type_name = :new) "
            "WHERE disaster_type_id IN "
            "(SELECT disaster_type_id FROM disaster_types WHERE type_name = :old)"
        ).bindparams(old=old, new=new))
    keep = ", ".join(f"'{name}'" for name in TYPES)  # constants above, no quotes in them
    op.execute(f"DELETE FROM disaster_types t WHERE t.type_name NOT IN ({keep}) AND {_UNUSED}")


def downgrade() -> None:
    _upsert(OLD_TYPES)
    op.execute(f"DELETE FROM disaster_types t WHERE t.type_name = 'Other' AND {_UNUSED}")
