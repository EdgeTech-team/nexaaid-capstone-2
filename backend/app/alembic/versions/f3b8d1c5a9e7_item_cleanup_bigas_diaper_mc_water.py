"""Item catalog clean-up: Bigas, Diapar, MC Water (Nov 2026).

These were typed in as "Something else" items, so they are in the catalog
next to the real ones:

1. "Bigas" is Rice. Every Bigas row is merged into Rice when both use the
   same unit: donations and delivery lines point at Rice, and a report's
   Bigas need / inventory is added to its Rice need / inventory (the
   tables are unique per report and item), then Bigas is deleted. A Bigas
   with another unit (e.g. "sacks" against Rice in kg) can't be added up
   safely, so it is retired instead (active = false: hidden from every
   dropdown, old records stay correct).
2. "Diapar" is a typo of "Diaper": renamed, or merged into "Diaper" the
   same way when that item already exists.
3. "MC Water" (and any "MC Water (unit)" copy typed after it was retired)
   is deleted when nothing uses it. Otherwise it is retired and its report
   needs are deleted, like migration c7a2d4f8e1b6.

services/donations/items.py maps a typed "Bigas" / "Diapar" to Rice / Diaper and
refuses "MC Water", so they don't come back.

Run scripts/recompute_priorities.py afterwards (dry run first): reports
whose needs were merged have new totals.

Downgrade does nothing: merged quantities can't be split again, and the
typo is not brought back.

Revision ID: f3b8d1c5a9e7
Revises: c2e4a6b8d0f1
"""
import sqlalchemy as sa
from alembic import op


revision = "f3b8d1c5a9e7"
down_revision = "c2e4a6b8d0f1"
branch_labels = None
depends_on = None


def _items_named(bind, name: str) -> list:
    """The item called `name`, and copies called "name (unit)"."""
    low = name.lower()
    return bind.execute(sa.text(
        "SELECT item_id, item_name, unit_of_measure, active FROM items "
        "WHERE lower(item_name) = :n OR lower(item_name) LIKE :copy "
        "ORDER BY item_id"
    ), {"n": low, "copy": f"{low} (%)"}).fetchall()


def _target(bind, name: str):
    return bind.execute(sa.text(
        "SELECT item_id, item_name, unit_of_measure, active FROM items "
        "WHERE lower(item_name) = :n ORDER BY active DESC, item_id LIMIT 1"
    ), {"n": name.lower()}).fetchone()


def _used(bind, item_id: int) -> int:
    return sum(bind.execute(sa.text(
        f"SELECT count(*) FROM {table} WHERE item_id = :i"), {"i": item_id}).scalar() or 0
        for table in ("report_needs", "physical_donations", "inventory", "delivery_items"))


def _merge_per_report(bind, table: str, src: int, dst: int) -> None:
    """Rows unique per (report, item): add src into an existing dst row of
    the same report, otherwise just move the row to dst."""
    bind.execute(sa.text(
        f"UPDATE {table} SET quantity = quantity + (SELECT s.quantity FROM {table} s "
        f"  WHERE s.item_id = :src AND s.report_id = {table}.report_id) "
        f"WHERE item_id = :dst AND report_id IN "
        f"  (SELECT report_id FROM {table} WHERE item_id = :src)"
    ), {"src": src, "dst": dst})
    bind.execute(sa.text(
        f"DELETE FROM {table} WHERE item_id = :src AND report_id IN "
        f"  (SELECT report_id FROM {table} WHERE item_id = :dst)"
    ), {"src": src, "dst": dst})
    bind.execute(sa.text(f"UPDATE {table} SET item_id = :dst WHERE item_id = :src"),
                 {"src": src, "dst": dst})


def _merge(bind, src, dst) -> None:
    """Every record of item `src` now counts for `dst`; `src` is deleted.
    Only called when both use the same base unit."""
    for table in ("physical_donations", "delivery_items"):
        bind.execute(sa.text(f"UPDATE {table} SET item_id = :dst WHERE item_id = :src"),
                     {"src": src.item_id, "dst": dst.item_id})
    _merge_per_report(bind, "report_needs", src.item_id, dst.item_id)
    _merge_per_report(bind, "inventory", src.item_id, dst.item_id)
    # Its sizes go with it (ON DELETE CASCADE on Postgres; explicit here).
    bind.execute(sa.text("DELETE FROM item_sizes WHERE item_id = :i"), {"i": src.item_id})
    bind.execute(sa.text("DELETE FROM items WHERE item_id = :i"), {"i": src.item_id})
    print(f"  merged {src.item_name!r} ({src.unit_of_measure}) into {dst.item_name!r}")


def _retire(bind, src, why: str) -> None:
    bind.execute(sa.text("UPDATE items SET active = false WHERE item_id = :i"), {"i": src.item_id})
    print(f"  retired {src.item_name!r}: {why}")


def _fold_into(bind, old: str, new: str, rename_when_missing: bool) -> None:
    for src in _items_named(bind, old):
        dst = _target(bind, new)
        if dst is None and rename_when_missing:
            bind.execute(sa.text("UPDATE items SET item_name = :n WHERE item_id = :i"),
                         {"n": new, "i": src.item_id})
            print(f"  renamed {src.item_name!r} to {new!r}")
            continue
        if dst is None:
            _retire(bind, src, f"no {new!r} item to merge it into")
        elif (src.unit_of_measure or "").strip().lower() == (dst.unit_of_measure or "").strip().lower():
            _merge(bind, src, dst)
        else:
            _retire(bind, src, f"unit {src.unit_of_measure!r} differs from {dst.item_name!r} "
                               f"({dst.unit_of_measure}); old records kept")


def upgrade() -> None:
    bind = op.get_bind()
    _fold_into(bind, "Bigas", "Rice", rename_when_missing=False)
    # The catalog may already have "Diapers" (plural): merge into that one.
    diaper = "Diapers" if _target(bind, "Diapers") is not None else "Diaper"
    _fold_into(bind, "Diapar", diaper, rename_when_missing=True)

    for src in _items_named(bind, "MC Water"):
        bind.execute(sa.text("DELETE FROM report_needs WHERE item_id = :i"), {"i": src.item_id})
        if _used(bind, src.item_id):
            _retire(bind, src, "used by donations, inventory or deliveries; old records kept")
        else:
            bind.execute(sa.text("DELETE FROM item_sizes WHERE item_id = :i"), {"i": src.item_id})
            bind.execute(sa.text("DELETE FROM items WHERE item_id = :i"), {"i": src.item_id})
            print(f"  deleted {src.item_name!r} (unused)")


def downgrade() -> None:
    # Merged quantities can't be split again; nothing to undo.
    pass
