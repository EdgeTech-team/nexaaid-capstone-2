"""Rice moves from sacks to kg (per-item fulfillment base units, Oct 2026)

Neon had Rice counted in "sack", but a sack is packaging (testing 2.5 / 4.1:
"100 sacks" said nothing about 25 kg or 50 kg). Its base unit becomes kg;
sizes such as "25 kg sack" (database/seeds/demo_seed.sql) say how much one
sack holds.

Same rule as Drinking Water in 9b3f7c1d2e48: if Rice was never used, only
its unit changes. If records use it, the old item is kept as "Rice (sacks,
old)" (inactive, its sizes removed, so those records stay correct) and a new
"Rice" in kg is added. Re-run demo_seed.sql afterwards to give the new item
its sizes.

Safe to re-run.

Revision ID: 7f4d2b9e6a31
Revises: 3e8a6f2c9d15
"""
from alembic import op


revision = "7f4d2b9e6a31"
down_revision = "3e8a6f2c9d15"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.execute(
        """
        DO $$
        DECLARE
            rid INTEGER;
        BEGIN
            SELECT item_id INTO rid FROM items
            WHERE lower(item_name) = 'rice'
              AND lower(unit_of_measure) IN ('sack', 'sacks');
            IF rid IS NULL THEN
                RETURN;
            END IF;
            IF EXISTS (SELECT 1 FROM physical_donations WHERE item_id = rid)
               OR EXISTS (SELECT 1 FROM inventory WHERE item_id = rid)
               OR EXISTS (SELECT 1 FROM delivery_items WHERE item_id = rid)
               OR EXISTS (SELECT 1 FROM report_needs WHERE item_id = rid) THEN
                UPDATE items SET item_name = 'Rice (sacks, old)', active = false
                WHERE item_id = rid;
                DELETE FROM item_sizes WHERE item_id = rid;
                INSERT INTO items (item_name, category, unit_of_measure)
                VALUES ('Rice', 'Food', 'kg');
            ELSE
                UPDATE items SET unit_of_measure = 'kg' WHERE item_id = rid;
            END IF;
        END $$;
        """
    )


def downgrade() -> None:
    # Data only (no schema change); nothing to undo.
    pass
