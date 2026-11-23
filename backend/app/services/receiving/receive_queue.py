"""
NF-003 (CSWS Main Office): the Receive screen's three tabs, 20 rows per page.

The Receive screen (mobile/lib/features/receiving/csws_screens.dart) used to download every
pending entry, every donation record and the whole inventory, then filter and
sort them in the app (mobile/lib/features/receiving/receive_filters.dart and
inventory_view.dart). The same rules run here, written again line for line:

  pending    entries still waiting, grouped by report. Pages hold 20 ENTRIES;
             each entry carries its report's label, priority and how many of
             the report's entries are shown, so the app groups a page's
             entries under their report again.
  received   entries with something received (not Pending).
  inventory  stock rows, grouped by report (report order = its first row
             after sorting).

The "When" filter counts calendar days in the phone's time zone (`tz`, minutes
east of UTC; the app sends it, Manila is +480).
"""
from datetime import datetime, timedelta, timezone
from typing import Optional

from fastapi import HTTPException

TABS = ("pending", "received", "inventory")
SORTS = ("urgent", "waiting_longest", "newest", "barangay_az")
WHENS = ("any", "today", "week", "month")
INVENTORY_SORTS = ("item_az", "quantity_high", "quantity_low", "last_updated")
_RANK = {"Critical": 0, "High": 1, "Medium": 2, "Low": 3}


def check(tab: str, sort: str, when: str, inventory_sort: str) -> None:
    for value, allowed, name in ((tab, TABS, "tab"), (sort, SORTS, "sort"),
                                 (when, WHENS, "when"), (inventory_sort, INVENTORY_SORTS, "inventory_sort")):
        if value not in allowed:
            raise HTTPException(status_code=422, detail=f"{name} must be one of: {', '.join(allowed)}")


def report_label(row: dict) -> str:
    r = row.get("report")
    return str(row.get("report_label") or (r.get("label") if isinstance(r, dict) else None)
               or f"Report #{row.get('report_id')}")


def barangay_of(row: dict) -> str:
    """The barangay name, taken from the report label ("#21 Typhoon - Banilad")."""
    label = report_label(row)
    for sep in (" - ", " in "):
        i = label.rfind(sep)
        if i >= 0:
            return label[i + len(sep):].strip()
    return "Unknown barangay"


def _when(value) -> Optional[datetime]:
    if value is None:
        return None
    if isinstance(value, datetime):
        d = value
    else:
        try:
            d = datetime.fromisoformat(str(value).replace("Z", "+00:00"))
        except ValueError:
            return None
    return d if d.tzinfo else d.replace(tzinfo=timezone.utc)


def _age_days(value, tz: int, now: datetime) -> Optional[int]:
    d = _when(value)
    if d is None:
        return None
    local = timezone(timedelta(minutes=tz))
    return (now.astimezone(local).date() - d.astimezone(local).date()).days


def in_when(value, when: str, tz: int, now: datetime) -> bool:
    if when == "any":
        return True
    age = _age_days(value, tz, now)
    if age is None:
        return False
    return age <= 0 if when == "today" else age < (7 if when == "week" else 30)


def matches(e: dict, search: Optional[str]) -> bool:
    q = (search or "").strip().lower()
    if not q:
        return True
    if q in str(e.get("batch_reference") or "").lower() or q in str(e.get("donor") or "").lower():
        return True
    return any(q in str(i.get("item_name") or "").lower() for i in e.get("items") or [])


def age(e: dict) -> float:
    """Older entries get smaller numbers (submitted time, else first item id)."""
    d = _when(e.get("created_at"))
    if d is not None:
        return d.timestamp() * 1000
    items = e.get("items") or []
    return float(items[0].get("donation_id") or 0) if items else 0.0


def _entry_ok(e, barangay, report_id, handover, when, tz, now, search) -> bool:
    return ((barangay is None or barangay_of(e) == barangay)
            and (report_id is None or e.get("report_id") == report_id)
            and (handover is None or e.get("handover_method") == handover)
            and in_when(e.get("created_at"), when, tz, now)
            and matches(e, search))


def pending_rows(groups: list, priorities: dict, *, barangay=None, report_id=None, handover=None,
                 when="any", tz=480, search=None, sort="urgent", now=None) -> list:
    """filterPendingReports, then the entries of each report in order, each
    with its report's details (the app groups them under the report again)."""
    now = now or datetime.now(timezone.utc)
    out = []
    for g in groups:
        if barangay is not None and barangay_of(g) != barangay:
            continue
        if report_id is not None and g["report_id"] != report_id:
            continue
        entries = [e for e in g["entries"]
                   if matches(e, search)
                   and (handover is None or e.get("handover_method") == handover)
                   and in_when(e.get("created_at"), when, tz, now)]
        if not entries:
            continue
        entries.sort(key=age, reverse=(sort == "newest"))
        out.append({**g, "entries": entries,
                    "priority_level": g.get("priority_level") or priorities.get(g["report_id"])})

    def oldest(g):
        return min(age(e) for e in g["entries"])

    def newest(g):
        return max(age(e) for e in g["entries"])

    if sort == "urgent":
        out.sort(key=lambda g: (_RANK.get(g["priority_level"], 4), oldest(g)))
    elif sort == "waiting_longest":
        out.sort(key=oldest)
    elif sort == "newest":
        out.sort(key=newest, reverse=True)
    else:
        out.sort(key=lambda g: (barangay_of(g).lower(), g["report_id"]))
    rows = []
    for g in out:
        for e in g["entries"]:
            rows.append({**e, "report_label": g.get("report_label"), "report_priority": g["priority_level"],
                         "report_waiting": len(g["entries"])})
    return rows


def received_rows(entries: list, *, barangay=None, report_id=None, handover=None, status=None,
                  when="any", tz=480, search=None, sort="urgent", now=None) -> list:
    """filterReceivedEntries."""
    now = now or datetime.now(timezone.utc)
    shown = [e for e in entries
             if e.get("status") != "Pending"
             and (status is None or e.get("status") == status)
             and _entry_ok(e, barangay, report_id, handover, when, tz, now, search)]
    # "Most urgent" is for choosing what to receive first (Pending tab);
    # received goods follow time, so it shows the newest first here.
    if sort == "waiting_longest":
        return sorted(shown, key=age)
    if sort == "barangay_az":
        return sorted(shown, key=lambda e: (barangay_of(e).lower(), -age(e)))
    return sorted(shown, key=age, reverse=True)


def inventory_rows(rows: list, *, barangay=None, report_id=None, search=None, sort="item_az") -> list:
    """filterInventoryRows + filterInventory: sorted, then grouped by report
    in the order of each report's first row, flattened."""
    q = (search or "").strip().lower()
    shown = [r for r in rows
             if (barangay is None or barangay_of(r) == barangay)
             and (report_id is None or r.get("report_id") == report_id)
             and q in str(r.get("item_name") or "").lower()]
    if sort == "quantity_high":
        shown.sort(key=lambda r: -(r.get("quantity") or 0))
    elif sort == "quantity_low":
        shown.sort(key=lambda r: r.get("quantity") or 0)
    elif sort == "last_updated":
        shown.sort(key=lambda r: (_when(r.get("last_updated")) or datetime.min.replace(tzinfo=timezone.utc)),
                   reverse=True)
    else:
        shown.sort(key=lambda r: str(r.get("item_name") or "").lower())
    groups: dict = {}
    for r in shown:
        groups.setdefault(report_label(r), []).append(r)
    return [r for g in groups.values() for r in g]


def options(rows: list, barangay: Optional[str]) -> tuple:
    """The Barangay and Report dropdowns, from every tab's rows."""
    barangays = sorted({barangay_of(r) for r in rows}, key=str.lower)
    reports = {}
    for r in rows:
        if barangay is None or barangay_of(r) == barangay:
            reports.setdefault(r.get("report_id"), report_label(r))
    ids = sorted((i for i in reports if i is not None), reverse=True)
    return barangays, [{"report_id": i, "report_label": reports[i]} for i in ids]
