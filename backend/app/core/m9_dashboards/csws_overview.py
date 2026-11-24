"""CSWS Main Office dashboard (Nov 23, 2026).

The overview has four cards (Waiting to be received, Expired or cancelled,
Entries received, Deliveries made), the scheduled deliveries (the app loads
them from GET /deliveries/), the inventory (6 items, then the Inventory
page) and the recent activity.

  waiting     donation entries (one QR) with a Pending item: the
              "Waiting to be received" card; due_today = a Pending item is
              due today (Philippine date) or earlier, its detail line

Inventory is what CSWS Main Office received and still holds:

  Summary     inventory rows summed per item across all reports (> 0)
  Per report  the stock held for each report, per item

There is no fulfillment or "still lacking" here (team, Nov 23): the
inventory shows what was received, not what reports need.
"""
import threading
import time as time_
from collections import defaultdict
from datetime import datetime, time, timedelta
from typing import Iterable, Optional

from fastapi import HTTPException
from sqlalchemy import func
from sqlalchemy.orm import Session, noload

from core.shared.audit_log_model import AuditLog
from core.m8_delivery_tracking.delivery_model import Delivery
from core.m5_inventory.inventory_model import Inventory
from core.reference_data.item_model import Item
from core.m4_donation_management.physical_donation_model import PhysicalDonation
from core.m2_disaster_reporting.report_model import Barangay, DisasterReport, DisasterType
from core.m1_user_management.user_rbac_model import User
from core.m4_donation_management.donation_expiry import MANILA, effective_deadline, now_utc, utc

# Inventory category chips -> items.category values. Anything else is Other.
CATEGORY_GROUPS = {
    "food_water": ("Food", "Water"),
    "health": ("Medical", "Hygiene"),
    "shelter": ("Shelter",),
}


def bad(name: str, value, allowed: Iterable[str]):
    allowed = tuple(allowed)
    if value is not None and value not in allowed:
        raise HTTPException(status_code=422, detail=f"{name} must be one of: {', '.join(allowed)}")


# ---------------------------------------------------------------------------
# Short-lived cache. The app asks for the overview several times at once
# (on open, after login, on live updates) and Neon's free tier can take
# 1-2 s per query when busy. Requests that arrive together wait for one
# computation and share it; the result is reused for a few seconds. Tests
# switch it off (tests/conftest.py).
# ---------------------------------------------------------------------------
CACHE = {"on": True}
_CACHED: dict = {}
# Re-entrant: building the overview reads other cached parts (expiry)
# from the same thread.
_CACHE_LOCK = threading.RLock()


def cached(key: str, seconds: float, build):
    if not CACHE["on"]:
        return build()
    with _CACHE_LOCK:
        hit = _CACHED.get(key)
        if hit is not None and time_.monotonic() - hit[0] < seconds:
            return hit[1]
        value = build()
        _CACHED[key] = (time_.monotonic(), value)
        return value


def clear_cache() -> None:
    _CACHED.clear()
    _LOOKUPS.clear()


_LOOKUPS: dict = {}
_LOOKUP_SECONDS = 60


def _lookups(db: Session) -> tuple:
    """(disaster types, barangays) as {id: name}. Fixed reference data,
    kept for a minute."""
    now = time_.monotonic()
    if not CACHE["on"] or _LOOKUPS.get("at", -1e9) + _LOOKUP_SECONDS < now:
        _LOOKUPS["types"] = {t.disaster_type_id: t.type_name for t in db.query(DisasterType).all()}
        _LOOKUPS["brgys"] = {b.barangay_id: b.barangay_name for b in db.query(Barangay).all()}
        _LOOKUPS["at"] = now
    return _LOOKUPS["types"], _LOOKUPS["brgys"]


# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------
def _iso(v) -> Optional[str]:
    v = utc(v)
    return v.isoformat() if v else None


def _today(now: datetime):
    return now.astimezone(MANILA).date()


def _days_since(when, now: datetime) -> int:
    when = utc(when)
    if when is None:
        return 0
    return max(0, (_today(now) - when.astimezone(MANILA).date()).days)


def matches(q: Optional[str], *texts) -> bool:
    if not q or not q.strip():
        return True
    needle = q.strip().lower()
    return any(needle in f"{t or ''}".lower() for t in texts)


def _amount(qty, unit) -> str:
    return f"{int(qty or 0):,} {unit or ''}".strip()


def _reports(db: Session, ids) -> dict:
    """{report_id: {"label": "#22 Fire", "barangay": "Casili", ...}}"""
    ids = set(ids) - {None}
    if not ids:
        return {}
    types, brgys = _lookups(db)
    R = DisasterReport
    # Columns only: loading the model also loads its needs and item sizes.
    rows = db.query(R.report_id, R.disaster_type_id, R.disaster_type_other, R.barangay_id,
                    R.affected_families, R.status, R.created_at
                    ).filter(R.report_id.in_(ids)).all()
    return {
        r.report_id: {
            "label": f"#{r.report_id} {r.disaster_type_other or types.get(r.disaster_type_id, 'Disaster')}",
            "barangay": brgys.get(r.barangay_id, "Barangay"),
            "families": r.affected_families,
            "status": r.status,
            "created_at": r.created_at,
        }
        for r in rows
    }


# ---------------------------------------------------------------------------
# Waiting to be received: donation entries with a Pending item
# ---------------------------------------------------------------------------
def donation_entries(db: Session, now: datetime) -> list:
    rows = (db.query(PhysicalDonation)
            .filter(PhysicalDonation.status == "Pending")
            .order_by(PhysicalDonation.donation_id).all())
    end_of_today = datetime.combine(_today(now) + timedelta(days=1), time.min, tzinfo=MANILA)
    groups: dict = defaultdict(list)
    for d in rows:
        groups[d.batch_reference or d.qr_reference].append(d)
    items = {i.item_id: i for i in db.query(Item).options(noload(Item.sizes)).filter(
        Item.item_id.in_({d.item_id for d in rows} or {-1})).all()}
    reports = _reports(db, {d.report_id for d in rows})
    out = []
    for ref, ds in groups.items():
        deadlines = [x for x in (effective_deadline(d) for d in ds) if x is not None]
        due = min(deadlines) if deadlines else None
        first = ds[0]
        item = items.get(first.item_id)
        rep = reports.get(first.report_id, {})
        created = min(utc(d.created_at) for d in ds)
        out.append({
            "kind": "donation",
            "batch_reference": ref,
            "donation_id": first.donation_id,
            "report_id": first.report_id,
            "report_label": rep.get("label"),
            "barangay": rep.get("barangay"),
            "handover_method": first.handover_method,
            "item_name": item.item_name if item else "Item",
            "item_category": item.category if item else None,
            "amount_text": _amount(first.quantity, item.unit_of_measure if item else ""),
            "more_items": len(ds) - 1,
            "created_at": _iso(created),
            "due_at": _iso(due),
            "days_waiting": _days_since(created, now),
            "late": due is not None and due < now,
            "due_today": due is not None and due < end_of_today,
        })
    return out


WAITING_SORTS = ("due_soonest", "longest_waiting", "newest")
HANDOVERS = ("Drop Off", "Door to Door")


def sort_entries(rows: list, sort: str) -> list:
    if sort == "due_soonest":
        return sorted(rows, key=lambda r: (r["due_at"] or "9999", r["created_at"] or ""))
    if sort == "newest":
        return sorted(rows, key=lambda r: r["created_at"] or "", reverse=True)
    return sorted(rows, key=lambda r: (r["created_at"] or "", r["donation_id"]))


def entry_search(rows: list, q: Optional[str]) -> list:
    return [r for r in rows if matches(q, r["batch_reference"], r["item_name"],
                                       r["report_label"], r["barangay"])]


# ---------------------------------------------------------------------------
# Inventory, Summary tab
# ---------------------------------------------------------------------------
def category_group(category: Optional[str]) -> str:
    for group, names in CATEGORY_GROUPS.items():
        if category in names:
            return group
    return "other"


def _stock_row(item: Item, qty, updated) -> dict:
    minimum = int(item.min_stock or 0)
    return {
        "item_id": item.item_id,
        "item_name": item.item_name,
        "category": item.category,
        "category_group": category_group(item.category),
        "unit": item.unit_of_measure,
        "quantity": int(qty or 0),
        "min_stock": minimum,
        "low": minimum > 0 and int(qty or 0) < minimum,
        "last_updated": _iso(updated),
    }


def _by_place(q, barangay_id: Optional[int], disaster_type_id: Optional[int]):
    """Only the stock held for reports in that barangay / of that disaster
    type (the Barangay and Disaster type filters of every report list)."""
    if barangay_id is None and disaster_type_id is None:
        return q
    q = q.join(DisasterReport, DisasterReport.report_id == Inventory.report_id)
    if barangay_id is not None:
        q = q.filter(DisasterReport.barangay_id == barangay_id)
    if disaster_type_id is not None:
        q = q.filter(DisasterReport.disaster_type_id == disaster_type_id)
    return q


def inventory_summary(db: Session, barangay_id: Optional[int] = None,
                      disaster_type_id: Optional[int] = None) -> list:
    """Stock per item, all reports added together; only items above 0."""
    q = (db.query(Item, func.sum(Inventory.quantity), func.max(Inventory.last_updated))
         .options(noload(Item.sizes))
         .join(Inventory, Inventory.item_id == Item.item_id))
    rows = (_by_place(q, barangay_id, disaster_type_id)
            .group_by(Item.item_id)
            .having(func.sum(Inventory.quantity) > 0).all())
    return [_stock_row(item, qty, updated) for item, qty, updated in rows]


INVENTORY_SORTS = ("lowest", "highest", "az", "last_updated")
INVENTORY_GROUPS = ("food_water", "health", "shelter", "other")


def sort_inventory(rows: list, sort: str) -> list:
    if sort == "highest":
        return sorted(rows, key=lambda r: (-r["quantity"], r["item_name"].lower()))
    if sort == "az":
        return sorted(rows, key=lambda r: r["item_name"].lower())
    if sort == "last_updated":
        return sorted(rows, key=lambda r: r["last_updated"] or "", reverse=True)
    if sort == "overview":   # low first, then the largest quantities
        return sorted(rows, key=lambda r: (not r["low"], -r["quantity"], r["item_name"].lower()))

    # lowest stock first: low items first, then furthest below the minimum
    def share(r):
        return r["quantity"] / r["min_stock"] if r["min_stock"] else float("inf")
    return sorted(rows, key=lambda r: (not r["low"], share(r), r["quantity"], r["item_name"].lower()))


# ---------------------------------------------------------------------------
# Inventory, Per report tab: what CSWS holds for each report
# ---------------------------------------------------------------------------
def report_stock(db: Session, report_id: Optional[int] = None,
                 barangay_id: Optional[int] = None,
                 disaster_type_id: Optional[int] = None) -> list:
    """One row per report that has stock: its items in stock (quantity > 0)."""
    q = (db.query(Inventory.report_id, Inventory.quantity, Inventory.last_updated, Item)
         .join(Item, Item.item_id == Inventory.item_id)
         .options(noload(Item.sizes))
         .filter(Inventory.quantity > 0))
    if report_id is not None:
        q = q.filter(Inventory.report_id == report_id)
    q = _by_place(q, barangay_id, disaster_type_id)
    by_report: dict = defaultdict(list)
    for rid, qty, updated, item in q.all():
        by_report[rid].append(_stock_row(item, qty, updated))
    reports = _reports(db, set(by_report))
    out = []
    for rid, items in by_report.items():
        rep = reports.get(rid, {})
        items.sort(key=lambda r: (-r["quantity"], r["item_name"].lower()))
        out.append({
            "report_id": rid,
            "report_label": rep.get("label") or f"#{rid}",
            "barangay": rep.get("barangay"),
            "families": rep.get("families"),
            "report_status": rep.get("status"),
            "created_at": _iso(rep.get("created_at")),
            "stock_items": len(items),
            "stock_units": sum(r["quantity"] for r in items),
            "last_updated": max((r["last_updated"] or "" for r in items), default="") or None,
            "top_items": items[:3],
            "items": items,
        })
    return out


PER_REPORT_SORTS = ("most_stock", "newest", "barangay", "last_updated")


def sort_reports(rows: list, sort: str) -> list:
    if sort == "newest":
        return sorted(rows, key=lambda r: (r["created_at"] or "", r["report_id"]), reverse=True)
    if sort == "barangay":
        return sorted(rows, key=lambda r: ((r["barangay"] or "").lower(), r["report_id"]))
    if sort == "last_updated":
        return sorted(rows, key=lambda r: (r["last_updated"] or "", r["report_id"]), reverse=True)
    return sorted(rows, key=lambda r: (-r["stock_units"], -r["report_id"]))


# ---------------------------------------------------------------------------
# The overview
# ---------------------------------------------------------------------------
def recent_activity(db: Session, limit: int = 10) -> list:
    """The latest donation, delivery and logistics actions (as before)."""
    q = (db.query(AuditLog, User.email).join(User, User.user_id == AuditLog.user_id)
         .filter(AuditLog.entity_type.in_(("physical_donations", "deliveries", "logistics_requests")))
         .order_by(AuditLog.log_id.desc()).limit(limit))
    return [{"action": log.action, "entity_type": log.entity_type, "entity_id": log.entity_id,
             "by": email, "at": _iso(log.timestamp)} for log, email in q.all()]


def overview(db: Session, now: Optional[datetime] = None) -> dict:
    now = now or now_utc()
    entries = donation_entries(db, now)
    counts = dict(db.query(PhysicalDonation.status, func.count(PhysicalDonation.donation_id))
                  .group_by(PhysicalDonation.status).all())
    stock = inventory_summary(db)
    reports_with_stock = (db.query(func.count(func.distinct(Inventory.report_id)))
                          .filter(Inventory.quantity > 0).scalar() or 0)
    return {
        # Waiting to be received: every pledge not received yet; the ones
        # due today or late are its detail line.
        "waiting": len(entries),
        "due_today": sum(1 for e in entries if e["due_today"]),
        # As before (copy-develop): donation items, and every delivery.
        "expired_donations": counts.get("Expired", 0),
        "cancelled_donations": counts.get("Cancelled", 0),
        "entries_received": counts.get("Received", 0) + counts.get("Confirmed", 0),
        "deliveries_made": db.query(func.count(Delivery.delivery_id)).scalar() or 0,
        "inventory": {"total": len(stock), "rows": sort_inventory(stock, "overview")[:6],
                      "reports_with_stock": reports_with_stock},
        "recent_activity": recent_activity(db),
    }
