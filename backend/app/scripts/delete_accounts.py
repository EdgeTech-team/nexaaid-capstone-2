"""Delete sample / test accounts so their emails can register again.

Testing feedback (Oct 2026): "After deleting sample data, creating a new
account still says email already registered." Deleting rows in Neon by hand
cannot remove a user who has reports, deliveries, receipts or logistics
requests (RESTRICT foreign keys), so those users stayed. This script deletes
them the same way the Administrator's Delete button does
(services/accounts.py): anonymized, email and employee ID freed, ID photos
removed, records kept under "Deleted User".

DRY RUN by default: lists the accounts that match and writes nothing.

    cd backend/app
    python scripts/delete_accounts.py --email someone@example.com
    python scripts/delete_accounts.py --match "%.sample@example.com"
    python scripts/delete_accounts.py --match "%@example.com" --apply --as-user testadmin@gmail.com

--email can be given several times; --match is a SQL LIKE pattern on the
email (case-insensitive). Administrator accounts and the --as-user account
are never deleted. --apply records one DELETE ACCOUNT entry per account in
the audit log under --as-user (an active Administrator) and asks you to
type APPLY first. Uses DATABASE_URL from .env, so check where it points.

Note: the demo seed's accounts (*.rep@example.com, *.test@example.com) also
end in @example.com. Read the dry-run list before applying a broad pattern.
"""
import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from sqlalchemy import func, or_, text  # noqa: E402

from core.auth import has_role  # noqa: E402
from models.user_rbac_model import User  # noqa: E402
from services.accounts import delete_account  # noqa: E402

import main  # noqa: E402,F401  (registers every model)


def find(db, emails=(), match=None, as_user=None) -> tuple:
    """(to_delete, skipped) — skipped holds (user, reason)."""
    if not emails and not match:
        return [], []
    conds = [func.lower(User.email) == e.strip().lower() for e in emails]
    if match:
        conds.append(func.lower(User.email).like(match.strip().lower()))
    users = (db.query(User).filter(User.deleted_at.is_(None), or_(*conds))
             .order_by(User.user_id).all())
    to_delete, skipped = [], []
    me = (as_user or "").strip().lower()
    for u in users:
        if u.email.lower() == me:
            skipped.append((u, "the --as-user account"))
        elif has_role(u, "Administrator"):
            skipped.append((u, "Administrator (delete it in the app instead)"))
        else:
            to_delete.append(u)
    return to_delete, skipped


def print_report(to_delete, skipped, out=print):
    if not to_delete:
        out("No account to delete matches.")
    else:
        out(f"{len(to_delete)} account(s) would be deleted:")
        out(f"{'id':>6}  {'email':<40} {'role':<34} {'active':<6}")
        for u in to_delete:
            role = u.role.role_name if u.role else "-"
            out(f"{u.user_id:>6}  {u.email[:40]:<40} {role[:34]:<34} {'yes' if u.is_active else 'no':<6}")
    for u, why in skipped:
        out(f"Skipped {u.email}: {why}.")


def run(db, emails=(), match=None, apply=False, as_user=None, ask=input, out=print) -> int:
    """Exit code: 0 ok, 1 cancelled, 2 bad arguments."""
    if not emails and not match:
        out("Give --email <address> (one or more) or --match <LIKE pattern>.")
        return 2
    if not apply and db.bind.dialect.name == "postgresql":
        db.execute(text("SET TRANSACTION READ ONLY"))
    to_delete, skipped = find(db, emails, match, as_user)
    print_report(to_delete, skipped, out)
    if not apply:
        if to_delete:
            out("Dry run: nothing was written. Re-run with --apply --as-user <admin email> to delete.")
        return 0
    if not to_delete:
        return 0
    admin = db.query(User).filter(func.lower(User.email) == (as_user or "").strip().lower()).first()
    if admin is None or not admin.is_active or not has_role(admin, "Administrator"):
        out("--apply needs --as-user <email of an active Administrator> (for the audit log).")
        return 2
    host = db.bind.url.host or db.bind.url.database
    if ask(f"Delete {len(to_delete)} account(s) on {host}? Type APPLY to continue: ").strip() != "APPLY":
        out("Cancelled. Nothing was written.")
        return 1
    for u in to_delete:
        delete_account(db, u, admin, source="scripts/delete_accounts.py")
    db.commit()
    out(f"Done: {len(to_delete)} account(s) deleted. Their emails can register again.")
    return 0


def main_cli(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--email", action="append", default=[], help="exact email (repeatable)")
    parser.add_argument("--match", help='SQL LIKE pattern on the email, e.g. "%%@example.com"')
    parser.add_argument("--apply", action="store_true", help="delete them (asks first)")
    parser.add_argument("--as-user", help="Administrator email recorded in the audit log")
    args = parser.parse_args(argv)
    from core.database import SessionLocal
    db = SessionLocal()
    try:
        return run(db, args.email, args.match, apply=args.apply, as_user=args.as_user)
    finally:
        db.rollback()
        db.close()


if __name__ == "__main__":
    sys.exit(main_cli())
