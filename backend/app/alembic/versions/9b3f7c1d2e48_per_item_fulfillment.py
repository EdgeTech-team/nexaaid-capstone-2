"""Per-item fulfillment: base units, item sizes, report needs (Oct 2026)

Fulfillment used to compare ONE total (estimated_quantity, e.g. "Rice 50 kg
+ Water 20 gal" stored as 70) against every delivered item, whatever it
was. Now each report lists its needs per item, every quantity is a whole
number in the item's base unit (kg, L, pcs...), and fulfillment is worked
out per need (services/fulfillment.py).

Changes (all additive; existing columns keep their meaning):
  - items.active: hides retired items from dropdowns, keeps old records.
  - item_sizes: common sizes per item (500 ml bottle = 0.5 L, 25 kg sack
    = 25 kg). Rows come from database/seeds/demo_seed.sql (fixed by devs).
  - report_needs: one row per needed item. Every existing report gets one
    "General needs" row (item_id NULL) with its old estimated_quantity, so
    its fulfillment percentage does not change.
  - physical_donations: pack_count, per_pack, size_amount, size_label
    (how the donor described it: 3 boxes x 16 x 1.5 L).
  - Drinking Water moves from gallons to liters. If water was never used,
    its unit is just changed. If records use it, the old item is kept as
    "Drinking Water (gallons, old)" (inactive, so those records stay
    correct) and a new "Drinking Water" in L is added.

Safe to re-run (IF NOT EXISTS / NOT EXISTS guards).

Revision ID: 9b3f7c1d2e48
Revises: d6e9a3b8c2f4
"""
from alembic import op


revision = "9b3f7c1d2e48"
down_revision = "d6e9a3b8c2f4"
branch_labels = None
depends_on = None


def upgrade() -> None:
    # --- items.active --------------------------------------------------------
    op.execute("ALTER TABLE items ADD COLUMN IF NOT EXISTS active BOOLEAN NOT NULL DEFAULT true")

    # --- item_sizes ------------------------------------------------------------
    op.execute(
        """
        CREATE TABLE IF NOT EXISTS item_sizes (
            size_id SERIAL PRIMARY KEY,
            item_id INTEGER NOT NULL,
            label VARCHAR(60) NOT NULL,
            amount NUMERIC(12, 4) NOT NULL,
            sort_order INTEGER NOT NULL DEFAULT 0,
            CONSTRAINT fk_item_sizes_item_id FOREIGN KEY (item_id)
                REFERENCES items (item_id) ON DELETE CASCADE,
            CONSTRAINT uq_item_sizes_item_label UNIQUE (item_id, label),
            CONSTRAINT chk_item_sizes_amount CHECK (amount > 0)
        )
        """
    )
    op.execute("CREATE INDEX IF NOT EXISTS ix_item_sizes_item_id ON item_sizes (item_id)")

    # --- report_needs ----------------------------------------------------------
    op.execute(
        """
        CREATE TABLE IF NOT EXISTS report_needs (
            need_id SERIAL PRIMARY KEY,
            report_id INTEGER NOT NULL,
            item_id INTEGER,
            quantity INTEGER NOT NULL,
            CONSTRAINT fk_report_needs_report_id FOREIGN KEY (report_id)
                REFERENCES disaster_reports (report_id) ON DELETE CASCADE,
            CONSTRAINT fk_report_needs_item_id FOREIGN KEY (item_id)
                REFERENCES items (item_id) ON DELETE RESTRICT,
            CONSTRAINT uq_report_needs_report_item UNIQUE (report_id, item_id),
            CONSTRAINT chk_report_needs_quantity CHECK (quantity > 0)
        )
        """
    )
    op.execute("CREATE INDEX IF NOT EXISTS ix_report_needs_report_id ON report_needs (report_id)")
    # Every existing report keeps its old total as one "General needs" row.
    op.execute(
        """
        INSERT INTO report_needs (report_id, item_id, quantity)
        SELECT r.report_id, NULL, r.estimated_quantity
        FROM disaster_reports r
        WHERE r.estimated_quantity > 0
          AND NOT EXISTS (SELECT 1 FROM report_needs n WHERE n.report_id = r.report_id)
        """
    )

    # --- physical_donations breakdown -----------------------------------------
    op.execute("ALTER TABLE physical_donations ADD COLUMN IF NOT EXISTS pack_count INTEGER")
    op.execute("ALTER TABLE physical_donations ADD COLUMN IF NOT EXISTS per_pack INTEGER")
    op.execute("ALTER TABLE physical_donations ADD COLUMN IF NOT EXISTS size_amount NUMERIC(12, 4)")
    op.execute("ALTER TABLE physical_donations ADD COLUMN IF NOT EXISTS size_label VARCHAR(60)")
    op.execute(
        """
        DO $$
        BEGIN
            IF NOT EXISTS (
                SELECT 1 FROM pg_constraint WHERE conname = 'chk_physical_donations_breakdown'
            ) THEN
                ALTER TABLE physical_donations ADD CONSTRAINT chk_physical_donations_breakdown CHECK (
                    (pack_count IS NULL OR pack_count > 0) AND (per_pack IS NULL OR per_pack > 0)
                    AND (size_amount IS NULL OR size_amount > 0)
                );
            END IF;
        END $$;
        """
    )

    # --- Drinking Water: gallons -> L ----------------------------------------
    op.execute(
        """
        DO $$
        DECLARE
            wid INTEGER;
        BEGIN
            SELECT item_id INTO wid FROM items
            WHERE lower(item_name) = 'drinking water'
              AND lower(unit_of_measure) IN ('gallon', 'gallons', 'gal');
            IF wid IS NULL THEN
                RETURN;
            END IF;
            IF EXISTS (SELECT 1 FROM physical_donations WHERE item_id = wid)
               OR EXISTS (SELECT 1 FROM inventory WHERE item_id = wid)
               OR EXISTS (SELECT 1 FROM delivery_items WHERE item_id = wid)
               OR EXISTS (SELECT 1 FROM report_needs WHERE item_id = wid) THEN
                UPDATE items SET item_name = 'Drinking Water (gallons, old)', active = false
                WHERE item_id = wid;
                INSERT INTO items (item_name, category, unit_of_measure)
                VALUES ('Drinking Water', 'Water', 'L');
            ELSE
                UPDATE items SET unit_of_measure = 'L' WHERE item_id = wid;
            END IF;
        END $$;
        """
    )


def downgrade() -> None:
    op.execute("ALTER TABLE physical_donations DROP CONSTRAINT IF EXISTS chk_physical_donations_breakdown")
    for col in ("size_label", "size_amount", "per_pack", "pack_count"):
        op.execute(f"ALTER TABLE physical_donations DROP COLUMN IF EXISTS {col}")
    op.execute("DROP TABLE IF EXISTS report_needs")
    op.execute("DROP TABLE IF EXISTS item_sizes")
    op.execute("ALTER TABLE items DROP COLUMN IF EXISTS active")
    # The Drinking Water rename is data, not schema; it is left as it is.
