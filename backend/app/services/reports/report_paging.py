"""
NF-003 (all roles): report lists a page at a time.

The report screens (Report Validation, Report Status, Validated Reports)
used to load every report and then filter by fulfillment status and sort in
the app. In paged mode the database does both, with the same rules the app
used (mobile/lib/features/reports/report_filters.dart):

  fulfillment  Not Started  percentage <= 0      (reports with a fulfillment row)
               In Progress  0 < percentage < 100
               Fulfilled    percentage >= 100
  sort         urgent           open first, then priority (Critical first),
                                then least fulfilled
               least_fulfilled  lowest percentage first
               most_fulfilled   highest percentage first
               most_families    most affected families first
               newest           newest report first

A report without a fulfillment row counts as 0% for sorting, as in the app.
Ties keep the old server order (newest first), so the order is stable and
pages never repeat or skip a report.
"""
from typing import Optional

from fastapi import HTTPException, Response
from sqlalchemy import case, func

from core.common.pagination import MAX_LIMIT, TOTAL_HEADER
from models.reports.report import DisasterReport, ReportFulfillment

FULFILLMENT_STATES = ("Not Started", "In Progress", "Fulfilled")
SORTS = ("urgent", "least_fulfilled", "most_fulfilled", "most_families", "newest")
_PRIORITY_RANK = ("critical", "high", "medium", "low")


def with_fulfillment(query):
    """Join each report's fulfillment row (if any) for filtering and sorting."""
    return query.outerjoin(ReportFulfillment, ReportFulfillment.report_id == DisasterReport.report_id)


def filter_fulfillment(query, state: Optional[str]):
    if not state:
        return query
    if state not in FULFILLMENT_STATES:
        raise HTTPException(status_code=422, detail=f"fulfillment must be one of: {', '.join(FULFILLMENT_STATES)}")
    pct = ReportFulfillment.fulfillment_percentage
    if state == "Fulfilled":
        return query.filter(pct >= 100)
    if state == "In Progress":
        return query.filter(pct > 0, pct < 100)
    return query.filter(pct <= 0)


def order(query, sort: Optional[str], editable_first_for: Optional[int] = None):
    """Sort like the app did. editable_first_for: the Disaster Unit's own
    Pending / Rejected reports come first (Report Status, "Only my reports")."""
    sort = sort or "urgent"
    if sort not in SORTS:
        raise HTTPException(status_code=422, detail=f"sort must be one of: {', '.join(SORTS)}")
    pct = func.coalesce(ReportFulfillment.fulfillment_percentage, 0)
    keys = []
    if editable_first_for is not None:
        keys.append(case((DisasterReport.status.in_(("Pending", "Rejected")), 0), else_=1))
    if sort == "urgent":
        level = func.lower(func.trim(func.coalesce(DisasterReport.priority_level, "")))
        rank = case(*[(level == p, i) for i, p in enumerate(_PRIORITY_RANK)], else_=len(_PRIORITY_RANK))
        keys += [case((pct >= 100, 1), else_=0), rank, pct]
    elif sort == "least_fulfilled":
        keys.append(pct.asc())
    elif sort == "most_fulfilled":
        keys.append(pct.desc())
    elif sort == "most_families":
        keys.append(func.coalesce(DisasterReport.affected_families, 0).desc())
    keys += [DisasterReport.created_at.desc(), DisasterReport.report_id.desc()]
    return query.order_by(*keys)


def page(query, response: Response, offset: int, limit: int):
    """One page plus X-Total-Count (counted before ordering)."""
    response.headers[TOTAL_HEADER] = str(query.order_by(None).count())
    return query.offset(offset).limit(min(limit, MAX_LIMIT)).all()


def fulfillment_counts(query) -> dict:
    """Reports per fulfillment status for the filter panel ("Not Started (9)")."""
    pct = ReportFulfillment.fulfillment_percentage
    state = case(
        (pct >= 100, "Fulfilled"),
        (pct > 0, "In Progress"),
        else_="Not Started",
    )
    counts = {s: 0 for s in FULFILLMENT_STATES}
    rows = (
        query.filter(pct.isnot(None))
        .with_entities(state, func.count(DisasterReport.report_id))
        .group_by(state)
        .order_by(None)
        .all()
    )
    for name, n in rows:
        counts[name] = n
    return counts
