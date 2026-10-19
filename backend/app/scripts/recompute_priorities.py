"""Recompute the fulfillment and priority of every validated report (Appendix H 3.1).

Run once after migration 9b3f7c1d2e48 (per-item fulfillment, option A
weights): reports validated before it still carry a level from the old
formula. New receipts and admin edits update priority on their own; this
script brings the existing reports in line.

DRY RUN by default: prints every report whose stored level differs from the
level the engine gives now, and writes nothing.

    cd backend/app
    python scripts/recompute_priorities.py
    python scripts/recompute_priorities.py --apply --as-user testadmin@gmail.com

--apply stores the new score, level and recommendation, records one
RECOMPUTE PRIORITY entry in the audit log under --as-user (an active
Administrator), and asks you to type APPLY first. Uses DATABASE_URL from
.env, so check where it points.
"""
import argparse
import os
import sys
from types import SimpleNamespace

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from sqlalchemy import func, text  # noqa: E402

from core.audit import log_action  # noqa: E402
from core.auth import has_role  # noqa: E402
from core.priority_engine import VALID_LEVELS, apply_priority, compute_priority  # noqa: E402
from models.report import DisasterReport  # noqa: E402
from services.fulfillment import progress, recalculate, status_for  # noqa: E402
from models.user_rbac_model import User  # noqa: E402

import main  # noqa: E402,F401  (registers every model)


def differences(db) -> list:
    rows = []
    reports = (db.query(DisasterReport)
               .filter(DisasterReport.status == "Validated")
               .order_by(DisasterReport.report_id).all())
    for r in reports:
        # Worked out in memory (the dry run writes nothing): the per-item
        # percentage, then the level the engine gives with it.
        f = r.fulfillment
        view = SimpleNamespace(
            affected_families=r.affected_families, estimated_quantity=r.estimated_quantity,
            assistance_needed=r.assistance_needed, disaster_type=r.disaster_type, fulfillment=None)
        if f is not None:
            pct = progress(db, r)["fulfillment_percentage"]
            view.fulfillment = SimpleNamespace(verification_status=status_for(pct),
                                               fulfillment_percentage=pct)
        level = compute_priority(view)["priority_level"]
        level = level if level in VALID_LEVELS else None
        if level != r.priority_level:
            f = r.fulfillment
            rows.append({
                "report_id": r.report_id,
                "old": r.priority_level,
                "new": level,
                "fulfillment": float(view.fulfillment.fulfillment_percentage) if view.fulfillment else None,
            })
    return rows


def print_report(diffs, out=print):
    if not diffs:
        out("Every validated report already has the current priority. Nothing to fix.")
        return
    out(f"{len(diffs)} report(s) have an outdated priority:")
    out(f"{'report':>7}  {'stored':<9} {'now':<9} {'fulfilled':>9}")
    for d in diffs:
        pct = "-" if d["fulfillment"] is None else f"{d['fulfillment']:.0f}%"
        out(f"{d['report_id']:>7}  {str(d['old']):<9} {str(d['new']):<9} {pct:>9}")


def run(db, apply=False, as_user=None, ask=input, out=print) -> int:
    """Exit code: 0 ok, 1 cancelled, 2 bad arguments."""
    if not apply and db.bind.dialect.name == "postgresql":
        db.execute(text("SET TRANSACTION READ ONLY"))
    diffs = differences(db)
    print_report(diffs, out)
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
    for d in diffs:
        report = db.get(DisasterReport, d["report_id"])
        if report.fulfillment is not None:
            recalculate(db, report.report_id, None)
            db.refresh(report)
        apply_priority(report)
    log_action(db, admin, "RECOMPUTE PRIORITY", "disaster_reports", None,
               new={"rows": diffs, "source": "scripts/recompute_priorities.py"})
    db.commit()
    out(f"Done: {len(diffs)} report(s) updated.")
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
