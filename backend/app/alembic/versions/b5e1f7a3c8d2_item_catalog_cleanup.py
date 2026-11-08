"""Item catalog clean-up (NF-006, Nov 2026).

1. Municipal Water ("MC Water") leaves the catalog: CSWS does not receive
   it. Its report needs are deleted first (1 row on Neon, Nov 8), then the
   item; its item_sizes go with it (ON DELETE CASCADE). Stops with an
   error if any donation, inventory or delivery line uses it.
2. Clothing is counted in pieces, with no set logic. The old "Clothing"
   (packs = sets) becomes "Clothing (packs, old)", inactive, so old records
   stay correct, and "Clothing – Upper" and "Clothing – Lower" (pcs) are
   added. CSWS bundles sets physically: 50 sets released = 50 Upper +
   50 Lower on the delivery.

After upgrading, run scripts/recompute_priorities.py (dry run first): the
report that lost its Municipal Water need has a new total.

Downgrade brings back Clothing and Municipal Water with its sizes, and
deletes the two new items only when nothing uses them. The deleted need
does not come back.

Revision ID: b5e1f7a3c8d2
Revises: a4d8c2e6f1b9
"""
import sqlalchemy as sa
from alembic import op


revision = "b5e1f7a3c8d2"
down_revision = "a4d8c2e6f1b9"
branch_labels = None
depends_on = None

CLOTHING = ("Clothing – Upper", "Clothing – Lower")
OLD_CLOTHING = "Clothing (packs, old)"

# Municipal Water's sizes (migration e1c7a4b9d352), for the downgrade.
MW_SIZES = [
    ("1 gallon container", 3.7854, 1),
    ("5 gallon container", 18.9271, 2),
    ("200 L drum", 200, 3),
    ("1,000 L water tank", 1000, 4),
]

_MW = "(SELECT item_id FROM items WHERE lower(item_name) = 'municipal water')"


def _unused(alias: str) -> str:
    return " AND ".join(
        f"NOT EXISTS (SELECT 1 FROM {table} x WHERE x.item_id = {alias}.item_id)"
        for table in ("report_needs", "physical_donations", "inventory", "delivery_items"))


def upgrade() -> None:
    used = op.get_bind().execute(sa.text(
        f"SELECT (SELECT count(*) FROM physical_donations WHERE item_id IN {_MW})"
        f"     + (SELECT count(*) FROM inventory WHERE item_id IN {_MW})"
        f"     + (SELECT count(*) FROM delivery_items WHERE item_id IN {_MW})"
    )).scalar()
    if used:
        raise RuntimeError(
            f"Municipal Water is used by {used} donation, inventory or delivery rows. "
            "Nothing was changed. Check them with the M5 owner before removing it.")
    op.execute(f"DELETE FROM report_needs WHERE item_id IN {_MW}")
    op.execute("DELETE FROM items WHERE lower(item_name) = 'municipal water'")

    op.execute(sa.text(
        "UPDATE items SET item_name = :old, active = false WHERE lower(item_name) = 'clothing'"
    ).bindparams(old=OLD_CLOTHING))
    for name in CLOTHING:
        op.execute(sa.text(
            "INSERT INTO items (item_name, category, unit_of_measure) "
            "SELECT :name, 'Clothing', 'pcs' "
            "WHERE NOT EXISTS (SELECT 1 FROM items WHERE lower(item_name) = lower(:name))"
        ).bindparams(name=name))


def downgrade() -> None:
    for name in CLOTHING:
        op.execute(sa.text(
            f"DELETE FROM items i WHERE i.item_name = :name AND {_unused('i')}"
        ).bindparams(name=name))
    op.execute(sa.text(
        "UPDATE items SET item_name = 'Clothing', active = true WHERE item_name = :old "
        "AND NOT EXISTS (SELECT 1 FROM items WHERE lower(item_name) = 'clothing')"
    ).bindparams(old=OLD_CLOTHING))

    op.execute(
        "INSERT INTO items (item_name, category, unit_of_measure) "
        "SELECT 'Municipal Water', 'Water', 'L' "
        "WHERE NOT EXISTS (SELECT 1 FROM items WHERE lower(item_name) = 'municipal water')"
    )
    for label, amount, order in MW_SIZES:
        op.execute(sa.text(
            "INSERT INTO item_sizes (item_id, label, amount, sort_order) "
            "SELECT i.item_id, :label, :amount, :order FROM items i "
            "WHERE lower(i.item_name) = 'municipal water' "
            "AND NOT EXISTS (SELECT 1 FROM item_sizes z WHERE z.item_id = i.item_id AND z.label = :label)"
        ).bindparams(label=label, amount=amount, order=order))
