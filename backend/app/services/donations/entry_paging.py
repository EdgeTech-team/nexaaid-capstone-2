"""NF-003: SQL-level paging for the staff donation records (Module 4.4 / 4.5).

GET /donations/records with ?limit= used to build EVERY entry in Python and
then slice one page. This module lets the database do the heavy part:

1. One grouped query, one row per entry (batch_reference), with the entry
   status, first donation id, item count, earliest deadline and the
   "Donation N" number (ROW_NUMBER per report) worked out in SQL.
2. The filters (status, report, handover, search, On Hold), the sort and
   LIMIT / OFFSET run on that grouped query, plus a COUNT for the total.
3. Only the rows of the entries on the page are loaded and turned into the
   usual entry dicts by services.donations.donation_entries.build_entries, so every
   field is exactly what the old answer had.

The rules mirror build_entries / group_by_report / filter_and_sort and
services.donations.donation_expiry.entry_status; tests/general/test_pagination.py checks that
the SQL pages put together equal the old full list for every filter and
sort. Without limit, receiving_routes still uses the old code unchanged.

Not used by GET /donations/mine (donor) or the dashboard.
"""
from typing import Optional, Tuple

from sqlalchemy import case, exists, false, func, or_, select
from sqlalchemy.orm import Session, aliased

from core.security.auth import barangay_scope
from models.donations.donation_confirmation_model import DonationConfirmation
from models.accounts.guest_donor_model import GuestDonor
from models.donations.item_model import Item
from models.donations.physical_donation_model import PhysicalDonation as PD
from models.reports.report import DisasterReport
from models.accounts.user_rbac_model import User
from services.donations.donation_entries import _report_labels, build_entries
from services.donations.donation_expiry import CLOSED, OPEN

ON_HOLD = "On Hold"


def _like(text: str) -> str:
    """'%text%' for LIKE, with % _ and \\ taken literally (Python's `in`)."""
    escaped = text.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")
    return f"%{escaped}%"


def _grouped(db: Session, own_barangay: Optional[int], report_id: Optional[int],
             disaster_type_id: Optional[int] = None, user_id: Optional[int] = None):
    """One row per entry in the caller's scope (subquery).

    own_barangay: a Barangay Receiving Representative's barangay.
    disaster_type_id (NF-001): only entries whose report is of that type; an
    unknown id simply matches nothing.
    user_id: a donor's own entries (GET /donations/mine/entries)."""
    is_open = ~PD.status.in_(CLOSED)
    total = func.count(PD.donation_id)
    n_open = func.sum(case((is_open, 1), else_=0))
    n_cancelled = func.sum(case((PD.status == "Cancelled", 1), else_=0))
    n_pending = func.sum(case((PD.status == OPEN, 1), else_=0))
    open_kinds = func.count(func.distinct(case((is_open, PD.status))))
    # services/donation_expiry.entry_status, in SQL
    status = case(
        (n_open == 0, case((n_cancelled == total, "Cancelled"), else_="Expired")),
        (open_kinds == 1, func.min(case((is_open, PD.status)))),
        (n_pending > 0, "Partly Received"),
        else_="Received",
    )
    first_id = func.min(PD.donation_id)
    report = func.min(PD.report_id)
    query = db.query(
        PD.batch_reference.label("ref"),
        first_id.label("first_id"),
        report.label("report_id"),
        total.label("total_items"),
        status.label("status"),
        # Earliest deadline of the items still Pending (entry_expiry_info);
        # expire_overdue fills expires_at for every Pending row first.
        func.min(case((PD.status == OPEN, PD.expires_at))).label("due"),
        # group_by_report: Donation 1, 2 ... per report, oldest first,
        # counted over every entry before any filter.
        func.row_number().over(partition_by=report, order_by=first_id).label("entry_no"),
    )
    if own_barangay is not None or disaster_type_id is not None:
        query = query.join(DisasterReport, DisasterReport.report_id == PD.report_id)
    if own_barangay is not None:
        query = query.filter(DisasterReport.barangay_id == own_barangay)
    if disaster_type_id is not None:
        query = query.filter(DisasterReport.disaster_type_id == disaster_type_id)
    if report_id is not None:
        query = query.filter(PD.report_id == report_id)
    if user_id is not None:
        query = query.filter(PD.user_id == user_id)
    return query.group_by(PD.batch_reference).subquery()


def _first_row(g):
    first = aliased(PD)
    return first, first.donation_id == g.c.first_id


def _handover_is(g, handover_method: str):
    # The entry's handover method is its first row's (build_entries).
    first, is_first = _first_row(g)
    return exists().where(
        is_first,
        func.lower(func.coalesce(first.handover_method, "")) == handover_method.strip().lower(),
    )


def _matches(g, search: str, staff: bool):
    """filter_and_sort's search: QR reference, donor (staff only), item name."""
    pattern = _like(search.strip().lower())
    any_row = aliased(PD)
    conditions = [
        func.lower(g.c.ref).like(pattern, escape="\\"),
        exists().where(
            any_row.batch_reference == g.c.ref,
            Item.item_id == any_row.item_id,
            func.lower(func.coalesce(Item.item_name, "")).like(pattern, escape="\\"),
        ),
    ]
    if staff:
        # The donor is the first row's user ("First Last", or the email when
        # both names are empty) or guest ("Name (guest)").
        first, is_first = _first_row(g)
        name = func.trim(func.coalesce(User.first_name, "") + " " + func.coalesce(User.last_name, ""))
        user_label = case((name == "", User.email), else_=name)
        guest_label = func.coalesce(GuestDonor.full_name, "None") + " (guest)"
        conditions += [
            exists().where(is_first, User.user_id == first.user_id,
                           func.lower(user_label).like(pattern, escape="\\")),
            exists().where(is_first, GuestDonor.guest_donor_id == first.guest_donor_id,
                           func.lower(guest_label).like(pattern, escape="\\")),
        ]
    return or_(*conditions)


def _on_hold(g):
    """build_entries' on_hold_items > 0: an item whose latest CMO decision is
    On Hold (with notes) and that is not Confirmed yet."""
    row = aliased(PD)
    latest = aliased(DonationConfirmation)
    newest_id = (
        select(func.max(latest.confirmation_id))
        .where(latest.donation_id == row.donation_id)
        .scalar_subquery()
    )
    return exists().where(
        row.batch_reference == g.c.ref,
        row.status != "Confirmed",
        exists().where(
            DonationConfirmation.donation_id == row.donation_id,
            DonationConfirmation.confirmation_id == newest_id,
            DonationConfirmation.status == ON_HOLD,
            DonationConfirmation.notes.isnot(None),
        ),
    )


def _filtered(db, g, staff, handover_method, search):
    query = db.query(g)
    if handover_method:
        query = query.filter(_handover_is(g, handover_method))
    if search and search.strip():
        query = query.filter(_matches(g, search, staff))
    return query


def _order(g, sort: str):
    if sort == "oldest":
        return (g.c.first_id.asc(),)
    if sort == "most_items":
        return (g.c.total_items.desc(), g.c.first_id.desc())
    if sort == "fewest_items":
        return (g.c.total_items.asc(), g.c.first_id.desc())
    if sort == "due_soonest":
        # Closest deadline first, entries with none last.
        return (g.c.due.is_(None).asc(), g.c.due.asc(), g.c.first_id.asc())
    return (g.c.first_id.desc(),)  # newest


def page_entries(
    db: Session,
    current_user: User,
    *,
    offset: int,
    limit: int,
    status: Optional[str] = None,
    report_id: Optional[int] = None,
    handover_method: Optional[str] = None,
    search: Optional[str] = None,
    sort: str = "newest",
    include_closed: bool = False,
    disaster_type_id: Optional[int] = None,
) -> Tuple[list, int]:
    """One page of entries and the total, the same as slicing the old
    GET /donations/records answer. Call expire_overdue(db) first."""
    own_barangay = barangay_scope(current_user)
    staff = own_barangay is None
    g = _grouped(db, own_barangay, report_id, disaster_type_id)
    query = _filtered(db, g, staff, handover_method, search)
    if not status and not include_closed:
        query = query.filter(~g.c.status.in_(CLOSED))
    if status:
        wanted = status.strip().lower()
        if wanted == "closed":
            query = query.filter(g.c.status.in_(CLOSED))
        elif wanted == ON_HOLD.lower():
            # A Barangay Receiving Representative never gets CMO details.
            query = query.filter(_on_hold(g) if staff else false())
        else:
            query = query.filter(func.lower(g.c.status) == wanted)

    total = query.count()
    page = (query.with_entities(g.c.ref, g.c.entry_no)
            .order_by(*_order(g, sort)).offset(offset).limit(limit).all())
    if not page:
        return [], total
    numbers = {ref: no for ref, no in page}
    rows = db.query(PD).filter(PD.batch_reference.in_(numbers)).all()
    built = {e["batch_reference"]: e
             for e in build_entries(db, rows, include_donor=staff, include_cmo=staff)}
    entries = []
    for ref, _ in page:
        entry = built[ref]
        entry["entry_no"] = numbers[ref]
        entries.append(entry)
    return entries, total


def entry_counts(
    db: Session,
    current_user: User,
    *,
    report_id: Optional[int] = None,
    handover_method: Optional[str] = None,
    search: Optional[str] = None,
    include_closed: bool = False,
    disaster_type_id: Optional[int] = None,
) -> dict:
    """GET /donations/records/counts in SQL: entries per status (+ On Hold),
    the "All" number, and the reports that have entries in scope (of the
    chosen disaster type, so the Report dropdown matches the list)."""
    own_barangay = barangay_scope(current_user)
    staff = own_barangay is None
    g = _grouped(db, own_barangay, None, disaster_type_id)

    report_ids = [r for (r,) in db.query(g.c.report_id).distinct().all()]
    labels = _report_labels(db, set(report_ids))
    reports = [{"report_id": rid, "report_label": labels.get(rid)}
               for rid in sorted(report_ids, reverse=True)]

    query = _filtered(db, g, staff, handover_method, search)
    if report_id is not None:
        query = query.filter(g.c.report_id == report_id)
    by_status = dict(query.with_entities(g.c.status, func.count()).group_by(g.c.status).all())
    by_status[ON_HOLD] = query.filter(_on_hold(g)).count() if staff else 0
    shown = sum(n for s, n in by_status.items()
                if s != ON_HOLD and (include_closed or s not in CLOSED))
    listed = query if include_closed else query.filter(~g.c.status.in_(CLOSED))
    items = listed.with_entities(func.coalesce(func.sum(g.c.total_items), 0)).scalar()
    # items: the item lines of the entries in "all" (the per-report summary).
    return {"all": shown, "items": int(items or 0), "by_status": by_status, "reports": reports}


def report_groups(
    db: Session,
    current_user: User,
    *,
    offset: int = 0,
    limit: Optional[int] = None,
    disaster_type_id: Optional[int] = None,
    include_closed: bool = True,
) -> Tuple[list, int]:
    """NF-001: the records screen's "Per report" view, grouped and paged in
    SQL. One row per report that has entries in the caller's scope, newest
    report first, with its entry count and entries per status."""
    own_barangay = barangay_scope(current_user)
    g = _grouped(db, own_barangay, None, disaster_type_id)
    scoped = db.query(g)
    if not include_closed:
        scoped = scoped.filter(~g.c.status.in_(CLOSED))
    reports = scoped.with_entities(g.c.report_id).group_by(g.c.report_id)
    total = reports.count()
    ordered = reports.order_by(g.c.report_id.desc())
    if limit is not None:
        ordered = ordered.offset(offset).limit(limit)
    ids = [rid for (rid,) in ordered.all()]
    if not ids:
        return [], total
    counts: dict = {rid: {} for rid in ids}
    for rid, status, n in (scoped.filter(g.c.report_id.in_(ids))
                           .with_entities(g.c.report_id, g.c.status, func.count())
                           .group_by(g.c.report_id, g.c.status).all()):
        counts[rid][status] = n
    labels = _report_labels(db, set(ids))
    return [{
        "report_id": rid,
        "report_label": labels.get(rid),
        "total_entries": sum(counts[rid].values()),
        "by_status": counts[rid],
    } for rid in ids], total
