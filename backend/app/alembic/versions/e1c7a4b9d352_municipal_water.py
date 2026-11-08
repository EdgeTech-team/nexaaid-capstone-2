"""The Municipal Water item (Concerns Nov 4).

New item "Municipal Water" (category Water, unit L), the city's water
supply, with a few common sizes. Every disaster's suggested needs include
it (services/need_templates.py). Skipped when an item with that name
already exists. (The typed name for "Other" disasters is Ivan's column
disaster_reports.disaster_type_other, migration e2b6d4a8c1f9.)

Additive only. Safe to re-run (NOT EXISTS guards). Downgrade removes
Municipal Water only when no report need, donation or inventory row uses it.

Revision ID: e1c7a4b9d352
Revises: e2b6d4a8c1f9
"""
from alembic import op


revision = "e1c7a4b9d352"
down_revision = "e2b6d4a8c1f9"
branch_labels = None
depends_on = None

SIZES = [
    ("1 gallon container", 3.7854, 1),
    ("5 gallon container", 18.9271, 2),
    ("200 L drum", 200, 3),
    ("1,000 L water tank", 1000, 4),
]


def upgrade() -> None:
    op.execute(
        """
        INSERT INTO items (item_name, category, unit_of_measure)
        SELECT 'Municipal Water', 'Water', 'L'
        WHERE NOT EXISTS (SELECT 1 FROM items WHERE lower(item_name) = 'municipal water')
        """
    )
    for label, amount, order in SIZES:
        op.execute(
            f"""
            INSERT INTO item_sizes (item_id, label, amount, sort_order)
            SELECT i.item_id, '{label}', {amount}, {order}
            FROM items i
            WHERE lower(i.item_name) = 'municipal water' AND i.unit_of_measure = 'L'
              AND NOT EXISTS (SELECT 1 FROM item_sizes z
                              WHERE z.item_id = i.item_id AND z.label = '{label}')
            """
        )


def downgrade() -> None:
    op.execute(
        """
        DELETE FROM items i
        WHERE lower(i.item_name) = 'municipal water'
          AND NOT EXISTS (SELECT 1 FROM report_needs n WHERE n.item_id = i.item_id)
          AND NOT EXISTS (SELECT 1 FROM physical_donations d WHERE d.item_id = i.item_id)
          AND NOT EXISTS (SELECT 1 FROM inventory v WHERE v.item_id = i.item_id)
        """
    )
