"""NF-008 (D6): organization categories and verification states.

organizations.organization_category VARCHAR(20) NOT NULL:
'Government' or 'Non-government', set from the organization type.
Existing rows are backfilled from their type; anything not recognised as a
government type is 'Non-government' (agreement A6).

The states shown to the organization and the Administrator are worked out
from columns that already exist (no new state column):
    Unverified   organizations.reviewed_at IS NULL
    Verified     organizations.reviewed_at IS NOT NULL
    Deactivated  the organization's account is deactivated
                 (users.is_active = false, users.deactivation_reason)

Safe to re-run (IF NOT EXISTS).

Revision ID: d4a7b2e8c6f1
Revises: c8f2a5d1e9b4
"""
from alembic import op


revision = "d4a7b2e8c6f1"
down_revision = "c8f2a5d1e9b4"
branch_labels = None
depends_on = None

CHECK = "chk_organizations_category"

# Old free labels ("Government") and the new fixed list (agreement A6).
GOVERNMENT_TYPES = (
    "Government",
    "Barangay / Barangay Council",
    "City or Municipal Government Office",
    "National Government Agency",
    "Public School or State University",
    "Government-Owned or Controlled Corporation",
)


def upgrade() -> None:
    op.execute("ALTER TABLE organizations ADD COLUMN IF NOT EXISTS organization_category VARCHAR(20)")
    listed = ", ".join("'" + t.replace("'", "''") + "'" for t in GOVERNMENT_TYPES)
    op.execute(
        f"UPDATE organizations SET organization_category = CASE "
        f"WHEN organization_type IN ({listed}) THEN 'Government' ELSE 'Non-government' END "
        f"WHERE organization_category IS NULL"
    )
    op.execute("ALTER TABLE organizations ALTER COLUMN organization_category SET DEFAULT 'Non-government'")
    op.execute("ALTER TABLE organizations ALTER COLUMN organization_category SET NOT NULL")
    op.execute(f"ALTER TABLE organizations DROP CONSTRAINT IF EXISTS {CHECK}")
    op.execute(
        f"ALTER TABLE organizations ADD CONSTRAINT {CHECK} CHECK "
        "(organization_category IN ('Government', 'Non-government'))"
    )


def downgrade() -> None:
    op.execute(f"ALTER TABLE organizations DROP CONSTRAINT IF EXISTS {CHECK}")
    op.execute("ALTER TABLE organizations DROP COLUMN IF EXISTS organization_category")
