"""Rebuild the inventory table from its source records (5.1.3).

    stock(item, report) = sum(received_goods.actual_quantity)
                        - sum(delivery_items.quantity)

DRY RUN by default: prints every (item, report) where the inventory table
disagrees, and writes nothing (the transaction is READ ONLY on Postgres).

    cd backend/app
    python scripts/rebuild_inventory.py
    python scripts/rebuild_inventory.py --apply --as-user testadmin@gmail.com

--apply sets each listed row to the expected quantity (creating missing
rows, never deleting any), records one REBUILD INVENTORY entry in the
audit log under --as-user (an active Administrator), and asks you to type
APPLY first. Uses DATABASE_URL from .env, so check where it points.
"""
import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from sqlalchemy import func, text  # noqa: E402

from core.audit import log_action  # noqa: E402
from core.auth import has_role  # noqa: E402
from models.inventory_model import Inventory  # noqa: E402
from models.item_model import Item  # noqa: E402
from models.user_rbac_model import User  # noqa: E402
from services.inventory import stock_differences  # noqa: E402

import main  # noqa: E402,F401  (registers every model)


def _labels(db):
    items = {i.item_id: i.item_name for i in db.query(Item).all()}
    return lambda d: items.get(d["item_id"], f"item #{d['item_id']}")


def print_report(db, diffs, out=print):
    if not diffs:
        out("Inventory matches received goods minus deliveries. Nothing to fix.")
        return
    name = _labels(db)
    out(f"{len(diffs)} inventory row(s) differ:")
    out(f"{'report':>7}  {'item':<30} {'inventory':>9} {'expected':>9} {'change':>8}")
    for d in diffs:
        have = "missing" if d["inventory"] is None else str(d["inventory"])
        out(f"{d['report_id']:>7}  {name(d)[:30]:<30} {have:>9} {d['expected']:>9} {d['difference']:>+8}")
    negative = [d for d in diffs if d["expected"] < 0]
    if negative:
        out(f"WARNING: {len(negative)} row(s) would go below zero (more delivered than "
            "received). They are skipped by --apply; check those deliveries by hand.")


def apply_fixes(db, diffs, admin) -> int:
    """Write the expected quantities. Returns how many rows changed."""
    changed = []
    for d in diffs:
        if d["expected"] < 0:
            continue
        row = (db.query(Inventory)
               .filter(Inventory.item_id == d["item_id"], Inventory.report_id == d["report_id"])
               .first())
        if row is None:
            db.add(Inventory(item_id=d["item_id"], report_id=d["report_id"], quantity=d["expected"]))
        else:
            row.quantity = d["expected"]          # last_updated is set by the model
        changed.append({k: d[k] for k in ("item_id", "report_id", "inventory", "expected")})
    if changed:
        log_action(db, admin, "REBUILD INVENTORY", "inventory", None,
                   new={"rows": changed, "source": "scripts/rebuild_inventory.py"})
    db.flush()
    return len(changed)


def run(db, apply=False, as_user=None, ask=input, out=print) -> int:
    """Exit code: 0 ok, 1 refused / nothing applied, 2 bad arguments."""
    if not apply and db.bind.dialect.name == "postgresql":
        db.execute(text("SET TRANSACTION READ ONLY"))
    diffs = stock_differences(db)
    print_report(db, diffs, out)
    if not apply:
        if diffs:
            out("Dry run: nothing was written. Re-run with --apply --as-user <admin email> to fix.")
        return 0
    if not diffs:
        return 0
    admin = db.query(User).filter(func.lower(User.email) == (as_user or "").strip().lower()).first()
    if admin is None or not admin.is_active or not has_role(admin, "Administrator"):
        out("--apply needs --as-user <email of an active Administrator> (for the audit log).")
        return 2
    host = db.bind.url.host or db.bind.url.database
    if ask(f"Write these changes to {host}? Type APPLY to continue: ").strip() != "APPLY":
        out("Cancelled. Nothing was written.")
        return 1
    n = apply_fixes(db, diffs, admin)
    db.commit()
    out(f"Done: {n} inventory row(s) updated.")
    return 0


def main_cli(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--apply", action="store_true", help="write the fixes (asks first)")
    parser.add_argument("--as-user", help="Administrator email recorded in the audit log")
    args = parser.parse_args(argv)
    from core.database import SessionLocal
    db = SessionLocal()
    try:
        return run(db, apply=args.apply, as_user=args.as_user)
    finally:
        db.rollback()
        db.close()


if __name__ == "__main__":
    sys.exit(main_cli())
