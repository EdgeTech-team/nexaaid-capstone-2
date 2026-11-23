"""CSWS Main Office dashboard pages (Nov 23, 2026).

Every page answers with a JSON array, 10 at a time with ?limit=10&offset=N
(X-Total-Count = matching rows), and has a /counts sibling for its filter
chips ("All (28)"). Rows come from services/csws_overview.py.

  GET /dashboard/csws-main/waiting   "Waiting to be received" card:
                                     every pledge not received yet
  GET /inventory/summary             Inventory, Summary tab
  GET /inventory/per-report          Inventory, Per report tab
  GET /inventory/per-report/{id}     The stock held for one report

Summary and Per report also take barangay_id and disaster_type_id, the
Barangay and Disaster type filters every report list has (Nov 24).
"""
from typing import Optional

from fastapi import APIRouter, Depends, HTTPException, Response
from sqlalchemy.orm import Session

from core.m1_user_management.auth import require_role
from core.shared.database import get_db
from core.shared.pagination import PageParams, paginate_list, set_total_header
from core.m9_dashboards import csws_overview as ov
from core.m4_donation_management.donation_expiry import now_utc

router = APIRouter(tags=["csws dashboard"])
ROLES = ("csws_main_office", "admin")
BASE = "/dashboard/csws-main"


def _send(response: Response, page: PageParams, rows: list) -> list:
    out, total = paginate_list(rows, page)
    set_total_header(response, page, total)
    return out


# ---------------------------------------------------------------------------
# Waiting to be received. filter: due (due today or late) or a handover method.
# ---------------------------------------------------------------------------
WAITING_FILTERS = ("due",) + ov.HANDOVERS


def _waiting(db, q):
    return ov.entry_search(ov.donation_entries(db, now_utc()), q)


def _waiting_filter(rows, f):
    if f == "due":
        return [r for r in rows if r["due_today"]]
    if f:
        return [r for r in rows if r["handover_method"] == f]
    return rows


@router.get(f"{BASE}/waiting")
def waiting(response: Response, filter: Optional[str] = None, q: Optional[str] = None,
            sort: str = "due_soonest", page: PageParams = Depends(),
            db: Session = Depends(get_db), user=Depends(require_role(*ROLES))):
    ov.bad("filter", filter, WAITING_FILTERS)
    ov.bad("sort", sort, ov.WAITING_SORTS)
    return _send(response, page, ov.sort_entries(_waiting_filter(_waiting(db, q), filter), sort))


@router.get(f"{BASE}/waiting/counts")
def waiting_counts(q: Optional[str] = None, db: Session = Depends(get_db),
                   user=Depends(require_role(*ROLES))):
    rows = _waiting(db, q)
    return {"all": len(rows), **{f: len(_waiting_filter(rows, f)) for f in WAITING_FILTERS}}


# ---------------------------------------------------------------------------
# Inventory: Summary and Per report (what CSWS received and still holds)
# ---------------------------------------------------------------------------
def _stock(db, q, barangay_id=None, disaster_type_id=None):
    return [r for r in ov.inventory_summary(db, barangay_id, disaster_type_id)
            if ov.matches(q, r["item_name"], r["category"])]


@router.get("/inventory/summary")
def inventory_summary(response: Response, category: Optional[str] = None,
                      q: Optional[str] = None, sort: str = "lowest",
                      barangay_id: Optional[int] = None,
                      disaster_type_id: Optional[int] = None,
                      page: PageParams = Depends(), db: Session = Depends(get_db),
                      user=Depends(require_role(*ROLES))):
    ov.bad("category", category, ov.INVENTORY_GROUPS)
    ov.bad("sort", sort, ov.INVENTORY_SORTS)
    rows = [r for r in _stock(db, q, barangay_id, disaster_type_id)
            if not category or r["category_group"] == category]
    return _send(response, page, ov.sort_inventory(rows, sort))


@router.get("/inventory/summary/counts")
def inventory_summary_counts(q: Optional[str] = None,
                             barangay_id: Optional[int] = None,
                             disaster_type_id: Optional[int] = None,
                             db: Session = Depends(get_db),
                             user=Depends(require_role(*ROLES))):
    rows = _stock(db, q, barangay_id, disaster_type_id)
    return {"all": len(rows), "low": sum(1 for r in rows if r["low"]),
            **{g: sum(1 for r in rows if r["category_group"] == g) for g in ov.INVENTORY_GROUPS}}


def _card(r: dict) -> dict:
    """A Per report card: everything but the full item list."""
    return {k: v for k, v in r.items() if k != "items"}


def _per_report(db, q, barangay_id=None, disaster_type_id=None):
    return [r for r in ov.report_stock(db, barangay_id=barangay_id,
                                       disaster_type_id=disaster_type_id)
            if ov.matches(q, r["report_label"], r["barangay"])]


@router.get("/inventory/per-report")
def per_report(response: Response, q: Optional[str] = None, sort: str = "most_stock",
               barangay_id: Optional[int] = None, disaster_type_id: Optional[int] = None,
               page: PageParams = Depends(), db: Session = Depends(get_db),
               user=Depends(require_role(*ROLES))):
    ov.bad("sort", sort, ov.PER_REPORT_SORTS)
    rows = _per_report(db, q, barangay_id, disaster_type_id)
    return _send(response, page, [_card(r) for r in ov.sort_reports(rows, sort)])


@router.get("/inventory/per-report/counts")
def per_report_counts(q: Optional[str] = None, barangay_id: Optional[int] = None,
                      disaster_type_id: Optional[int] = None,
                      db: Session = Depends(get_db), user=Depends(require_role(*ROLES))):
    return {"all": len(_per_report(db, q, barangay_id, disaster_type_id))}


@router.get("/inventory/per-report/{report_id}")
def report_stock(report_id: int, response: Response, category: Optional[str] = None,
                 q: Optional[str] = None, sort: str = "highest", page: PageParams = Depends(),
                 db: Session = Depends(get_db), user=Depends(require_role(*ROLES))):
    """The items CSWS holds for one report."""
    ov.bad("category", category, ov.INVENTORY_GROUPS)
    ov.bad("sort", sort, ov.INVENTORY_SORTS)
    rows = ov.report_stock(db, report_id)
    if not rows:
        raise HTTPException(status_code=404, detail="CSWS holds no stock for that report.")
    items = [i for i in rows[0]["items"] if ov.matches(q, i["item_name"], i["category"])
             and (not category or i["category_group"] == category)]
    return _send(response, page, ov.sort_inventory(items, sort))


@router.get("/inventory/per-report/{report_id}/counts")
def report_stock_counts(report_id: int, q: Optional[str] = None, db: Session = Depends(get_db),
                        user=Depends(require_role(*ROLES))):
    rows = ov.report_stock(db, report_id)
    items = [i for i in (rows[0]["items"] if rows else [])
             if ov.matches(q, i["item_name"], i["category"])]
    return {"all": len(items),
            **{g: sum(1 for i in items if i["category_group"] == g) for g in ov.INVENTORY_GROUPS}}
