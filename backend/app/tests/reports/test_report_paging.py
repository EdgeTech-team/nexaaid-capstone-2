"""
NF-003 (all roles): report lists a page at a time.

The app used to load every report and filter / sort them itself
(mobile/lib/features/reports/report_filters.dart, sortAndFilterReports). In paged mode the
server must give exactly the same rows in exactly the same order, split into
pages with no repeats and no gaps. Without `offset` the answer is unchanged
for installed APKs.
"""
from datetime import datetime, timedelta, timezone
from decimal import Decimal

import pytest

from core.config import database
from models.reports.report import DisasterReport, ReportFulfillment
from models.accounts.user_rbac_model import User
from tests.general.test_role_flows import api, ok  # noqa: F401  (fixture)

PRIORITY = ["Critical", "High", "Medium", "Low"]
STATES = ["Not Started", "In Progress", "Fulfilled"]


def _seed(n=17):
    """n reports with a mix of statuses, priorities, families and fulfillment.
    Some timestamps are equal on purpose (ties must still page cleanly)."""
    db = database.SessionLocal()
    unit = db.query(User).filter(User.email == "rico.test@example.com").one()
    base = datetime(2026, 11, 1, tzinfo=timezone.utc)
    pcts = [None, 0, 0, 12.5, 40, 99.99, 100, 100, 55, None, 0, 75, 100, 5, 30, None, 60]
    for i in range(n):
        r = DisasterReport(
            user_id=unit.user_id, disaster_type_id=1, barangay_id=1, source="Web",
            status="Validated" if i % 4 else ["Pending", "Rejected", "Validated", "Cancelled"][i // 4 % 4],
            affected_families=(i * 7) % 11 or None,
            priority_level=[*PRIORITY, None, "needs review"][i % 6],
            created_at=base + timedelta(hours=i // 3),  # 3 reports share each time
        )
        db.add(r)
        db.flush()
        pct = pcts[i % len(pcts)]
        if pct is not None:
            db.add(ReportFulfillment(report_id=r.report_id, total_items_needed=100,
                                     total_items_delivered=int(pct), fulfillment_percentage=Decimal(str(pct))))
    db.commit()
    db.close()


# --- the app's rules (report_filters.dart), written again in Python --------
def _pct(r):
    p = r.get("fulfillment_percentage")
    return None if p is None else float(p)


def _state(r):
    p = _pct(r)
    if p is None:
        return None
    return "Fulfilled" if p >= 100 else "In Progress" if p > 0 else "Not Started"


def _rank(p):
    p = (p or "").strip().lower()
    levels = [x.lower() for x in PRIORITY]
    return levels.index(p) if p in levels else len(levels)


def app_order(rows, fulfillment=None, sort="urgent"):
    rows = [r for r in rows if fulfillment is None or _state(r) == fulfillment]
    pct = lambda r: _pct(r) or 0  # noqa: E731
    keys = {
        "urgent": lambda r: (1 if pct(r) >= 100 else 0, _rank(r["priority_level"]), pct(r)),
        "least_fulfilled": lambda r: pct(r),
        "most_fulfilled": lambda r: -pct(r),
        "most_families": lambda r: -(r["affected_families"] or 0),
        "newest": lambda r: -r["report_id"],
    }
    return sorted(rows, key=keys[sort])  # stable: keeps the server's newest-first order


def all_pages(client, headers, path, size=4, **params):
    seen, total, offset = [], None, 0
    while True:
        r = client.get(path, headers=headers, params={**params, "limit": size, "offset": offset})
        assert r.status_code == 200, r.text
        total = int(r.headers["x-total-count"])
        page = r.json()
        seen += page
        offset += len(page)
        if len(page) < size:
            break
    assert len(seen) == total
    assert len({r["report_id"] for r in seen}) == len(seen), "a report repeated across pages"
    return seen


@pytest.mark.parametrize("sort", ["urgent", "least_fulfilled", "most_fulfilled", "most_families", "newest"])
@pytest.mark.parametrize("fulfillment", [None, *STATES])
def test_validated_pages_match_the_apps_filter_and_sort(api, sort, fulfillment):
    client, t = api
    _seed()
    everything = ok(client.get("/reports/validated", headers=t["cmo"], params={"limit": 200}))
    expected = app_order(everything, fulfillment, sort)
    params = {"sort": sort, **({"fulfillment": fulfillment} if fulfillment else {})}
    got = all_pages(client, t["cmo"], "/reports/validated", **params)
    if sort in ("urgent", "least_fulfilled", "most_fulfilled", "most_families"):
        # Equal keys keep newest-first; compare the sort keys and the set.
        key = {"urgent": lambda r: (1 if (_pct(r) or 0) >= 100 else 0, _rank(r["priority_level"]), _pct(r) or 0),
               "least_fulfilled": lambda r: _pct(r) or 0,
               "most_fulfilled": lambda r: -(_pct(r) or 0),
               "most_families": lambda r: -(r["affected_families"] or 0)}[sort]
        assert [key(r) for r in got] == [key(r) for r in expected]
        assert sorted(r["report_id"] for r in got) == sorted(r["report_id"] for r in expected)
    else:
        assert [r["report_id"] for r in got] == [r["report_id"] for r in expected]


def test_monitoring_status_priority_and_counts(api):
    client, t = api
    _seed()
    everything = ok(client.get("/reports/monitoring", headers=t["admin"], params={"limit": 200}))
    for status in (None, "Validated", "Pending", "Rejected", "Cancelled"):
        rows = [r for r in everything if status is None or r["status"] == status]
        params = {"status": status} if status else {}
        got = all_pages(client, t["admin"], "/reports/monitoring", sort="newest", **params)
        assert [r["report_id"] for r in got] == [r["report_id"] for r in app_order(rows, sort="newest")]
        counts = ok(client.get("/reports/monitoring/counts", headers=t["admin"], params=params))
        assert counts == {s: sum(1 for r in rows if _state(r) == s) for s in STATES}

    high = all_pages(client, t["admin"], "/reports/monitoring", priority_level="High")
    assert high and all(r["priority_level"] == "High" for r in high)


def test_only_my_reports_puts_editable_ones_first(api):
    client, t = api
    _seed()
    mine = all_pages(client, t["unit"], "/reports/monitoring", mine="true", sort="newest")
    assert mine
    editable = [r["status"] in ("Pending", "Rejected") for r in mine]
    assert editable == sorted(editable, reverse=True)  # all editable ones first
    # Another staff member's "mine" holds none of the unit's reports.
    assert all_pages(client, t["admin"], "/reports/monitoring", mine="true") == []


def test_admin_validation_queue_pages_by_status(api):
    client, t = api
    _seed()
    for status in ("Pending", "Rejected"):
        old = ok(client.get("/reports/", headers=t["admin"], params={"status": status, "limit": 200}))
        got = all_pages(client, t["admin"], "/reports/", size=2, status=status, sort="newest")
        assert [r["report_id"] for r in got] == sorted((r["report_id"] for r in old), reverse=True)


def test_without_offset_nothing_changes_for_old_apps(api):
    client, t = api
    _seed()
    for path, who in (("/reports/validated", "cmo"), ("/reports/monitoring", "admin"), ("/reports/", "admin")):
        r = client.get(path, headers=t[who])
        assert r.status_code == 200
        assert "x-total-count" not in r.headers
        ids = [x["report_id"] for x in r.json()]
        assert ids == sorted(ids, key=lambda i: ids.index(i))  # unchanged newest-first list
    # The old default caps are kept as they were.
    assert len(ok(client.get("/reports/validated", headers=t["cmo"], params={"limit": 3}))) == 3


def test_bad_values_and_roles(api):
    client, t = api
    assert client.get("/reports/validated", headers=t["cmo"], params={"offset": 0, "sort": "bogus"}).status_code == 422
    assert client.get("/reports/validated", headers=t["cmo"], params={"offset": 0, "fulfillment": "Half"}).status_code == 422
    assert client.get("/reports/validated", headers=t["cmo"], params={"offset": -1}).status_code == 422
    assert client.get("/reports/validated/counts", headers=t["donor"]).status_code == 200
    assert client.get("/reports/monitoring/counts", headers=t["donor"]).status_code == 403
    assert client.get("/reports/monitoring", headers=t["donor"], params={"offset": 0}).status_code == 403
