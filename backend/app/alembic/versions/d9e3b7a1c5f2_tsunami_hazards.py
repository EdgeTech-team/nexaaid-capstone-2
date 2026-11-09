"""Tsunami is location-specific; pending hazard rows say so (NF-004, PR #110 follow-up).

1. disaster_types: Tsunami becomes location-specific. It floods the same
   coastal barangays as Storm Surge, so it gets the same lists: confirmed
   Paknaan, Umapad, Opao, Looc (the confirmed source text) and pending
   Subangdaku, Tipolo, Centro, Labogon.
2. Every pending row, Storm Surge and Tsunami, gets source =
   'PENDING CDRRMO confirmation', so the table itself says which rows are
   not confirmed yet (a4d8c2e6f1b9 gave them the confirmed source text).

Inserts skip an existing pair (ON CONFLICT), so it is safe to re-run.

Downgrade deletes every Tsunami row, makes Tsunami general again and gives
the pending Storm Surge rows the confirmed source text, as a4d8c2e6f1b9
left them.

Revision ID: d9e3b7a1c5f2
Revises: c7a2d4f8e1b6
"""
import sqlalchemy as sa
from alembic import op


revision = "d9e3b7a1c5f2"
down_revision = "c7a2d4f8e1b6"
branch_labels = None
depends_on = None

SOURCE = "Mandaue CDRRMO public statements / city barangay map"
PENDING_SOURCE = "PENDING CDRRMO confirmation"

# Confirmed. Names exactly as in the barangays table.
CONFIRMED = ["Paknaan", "Umapad", "Opao", "Looc"]

# PENDING CDRRMO confirmation (Storm Surge and Tsunami). Same list as
# PENDING_HAZARDS in a4d8c2e6f1b9.
PENDING = ["Subangdaku", "Tipolo", "Centro", "Labogon"]


def _insert(type_name: str, barangay: str, source: str) -> None:
    op.execute(sa.text(
        "INSERT INTO barangay_hazards (barangay_id, disaster_type_id, source) "
        "SELECT b.barangay_id, t.disaster_type_id, :source "
        "FROM barangays b JOIN disaster_types t ON t.type_name = :type_name "
        "WHERE b.barangay_name = :barangay "
        "ON CONFLICT (barangay_id, disaster_type_id) DO NOTHING"
    ).bindparams(source=source, type_name=type_name, barangay=barangay))


def _set_source(type_name: str, barangays: list, source: str) -> None:
    for barangay in barangays:
        op.execute(sa.text(
            "UPDATE barangay_hazards h SET source = :source "
            "FROM barangays b, disaster_types t "
            "WHERE h.barangay_id = b.barangay_id AND h.disaster_type_id = t.disaster_type_id "
            "AND b.barangay_name = :barangay AND t.type_name = :type_name"
        ).bindparams(source=source, type_name=type_name, barangay=barangay))


def upgrade() -> None:
    op.execute("UPDATE disaster_types SET is_location_specific = true WHERE type_name = 'Tsunami'")
    for barangay in CONFIRMED:
        _insert("Tsunami", barangay, SOURCE)
    for barangay in PENDING:
        _insert("Tsunami", barangay, PENDING_SOURCE)
    _set_source("Storm Surge", PENDING, PENDING_SOURCE)
    _set_source("Tsunami", PENDING, PENDING_SOURCE)   # a pair that already existed


def downgrade() -> None:
    op.execute(
        "DELETE FROM barangay_hazards WHERE disaster_type_id IN "
        "(SELECT disaster_type_id FROM disaster_types WHERE type_name = 'Tsunami')"
    )
    op.execute("UPDATE disaster_types SET is_location_specific = false WHERE type_name = 'Tsunami'")
    _set_source("Storm Surge", PENDING, SOURCE)
