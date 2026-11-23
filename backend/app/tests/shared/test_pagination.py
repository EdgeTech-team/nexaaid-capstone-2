"""
NF-003 (T1): pagination foundation.

- core/shared/pagination.py: limit / offset validation, the clamp at 100, the
  X-Total-Count header, paging a list and a SQL query.
- Pilot GET /donations/records (Module 4.4 / 4.5): no limit = byte-for-byte
  the old answer; pages hold every entry exactly once in a stable order even
  when timestamps are equal; "Donation N" numbers survive slicing; filters
  and paging together; status=On Hold.
- GET /donations/records/counts: same filters as the list, same role scope.
- CORS exposes X-Total-Count to the web build.
"""
from datetime import datetime, timedelta, timezone

from fastapi import Depends, FastAPI, Response
from fastapi.encoders import jsonable_encoder
from fastapi.responses import JSONResponse
from fastapi.testclient import TestClient
import pytest

from core.shared import database
from core.m1_user_management.auth import barangay_scope
from core.shared.pagination import (
    MAX_LIMIT, TOTAL_HEADER, PageParams, paginate_list, paginate_query, set_total_header,
)
from core.reference_data.disaster_type_model import DisasterType
from core.m6_city_confirmation.donation_confirmation_model import DonationConfirmation
from core.m4_donation_management.physical_donation_model import PhysicalDonation
from core.m2_disaster_reporting.report_model import DisasterReport
from core.m1_user_management.user_rbac_model import User
from core.m4_donation_management.donation_entries import ENTRY_SORTS, build_entries, filter_and_sort, group_by_report
from core.m4_donation_management.donation_expiry import CLOSED, expire_overdue
from tests.m4_donation_management.test_donation_batch import LINE, _report
from tests.m1_user_management.test_role_flows import api, ok  # noqa: F401  (fixture)


# ---------------------------------------------------------------------------
# The helper on its own (a tiny app, so no database is needed)
# ---------------------------------------------------------------------------

mini = FastAPI()
NUMBERS = list(range(250))


@mini.get("/numbers")
def numbers(response: Response, page: PageParams = Depends()):
    rows, total = paginate_list(NUMBERS, page)
    set_total_header(response, page, total)
    return rows


@pytest.fixture()
def mini_client():
    return TestClient(mini)


def test_no_limit_returns_everything_without_the_header(mini_client):
    r = mini_client.get("/numbers")
    assert r.json() == NUMBERS
    assert TOTAL_HEADER.lower() not in r.headers
    # offset alone does not start paging
    assert mini_client.get("/numbers", params={"offset": 10}).json() == NUMBERS


def test_limit_and_offset_return_one_page_and_the_total(mini_client):
    r = mini_client.get("/numbers", params={"limit": 20, "offset": 40})
    assert r.json() == list(range(40, 60))
    assert r.headers[TOTAL_HEADER] == "250"
    last = mini_client.get("/numbers", params={"limit": 20, "offset": 240})
    assert last.json() == list(range(240, 250))
    past = mini_client.get("/numbers", params={"limit": 20, "offset": 999})
    assert past.json() == [] and past.headers[TOTAL_HEADER] == "250"


def test_limit_above_100_is_clamped(mini_client):
    r = mini_client.get("/numbers", params={"limit": 500})
    assert len(r.json()) == MAX_LIMIT == 100
    assert r.headers[TOTAL_HEADER] == "250"


@pytest.mark.parametrize("params", [
    {"limit": 0}, {"limit": -5}, {"offset": -1}, {"limit": 10, "offset": -1}, {"limit": "abc"},
])
def test_bad_limit_or_offset_is_422(mini_client, params):
    assert mini_client.get("/numbers", params=params).status_code == 422


def test_paginate_query_counts_and_pages_with_the_same_filters(db_session):
    db_session.add_all([DisasterType(type_name=f"Type {i:02d}") for i in range(1, 26)])
    db_session.commit()
    query = db_session.query(DisasterType).filter(DisasterType.type_name.like("Type 1%"))
    order = (DisasterType.type_name.desc(), DisasterType.disaster_type_id.desc())

    page = PageParams(limit=4, offset=0)
    rows, total = paginate_query(query, page, *order)
    assert total == 10  # Type 10 .. Type 19
    assert [r.type_name for r in rows] == ["Type 19", "Type 18", "Type 17", "Type 16"]

    seen = []
    for offset in range(0, total, 4):
        seen += [r.disaster_type_id for r in paginate_query(query, PageParams(limit=4, offset=offset), *order)[0]]
    assert len(seen) == len(set(seen)) == total

    everything, total_all = paginate_query(query, PageParams(limit=None, offset=0), *order)
    assert len(everything) == total_all == 10

    with pytest.raises(ValueError):
        paginate_query(query, page)  # no stable order given


# ---------------------------------------------------------------------------
# Pilot: GET /donations/records
# ---------------------------------------------------------------------------

def _entries(client, t, rid, n, method="Drop Off"):
    refs = []
    for i in range(n):
        b = ok(client.post("/donations/batch", headers=t["donor"], json={
            "report_id": rid, "handover_method": method,
            "items": [{**LINE, "quantity": i + 1}] * (1 + i % 3)}), 201)
        refs.append(b["batch_reference"])
    return refs


def _all_pages(client, headers, size, **params):
    """Walk every page; return (rows, totals seen on each page)."""
    rows, totals, offset = [], set(), 0
    while True:
        r = client.get("/donations/records", headers=headers,
                       params={**params, "limit": size, "offset": offset})
        page = ok(r)
        totals.add(int(r.headers[TOTAL_HEADER]))
        rows += page
        if len(page) < size:
            return rows, totals
        offset += size


def _old_records(user_email, status=None, report_id=None, handover_method=None,
                 q=None, sort="newest", include_closed=False):
    """GET /donations/records exactly as it was before NF-003."""
    db = database.SessionLocal()
    try:
        user = db.query(User).filter(User.email == user_email).one()
        expire_overdue(db)
        own_barangay = barangay_scope(user)
        query = db.query(PhysicalDonation)
        if own_barangay is not None:
            query = query.join(
                DisasterReport, DisasterReport.report_id == PhysicalDonation.report_id
            ).filter(DisasterReport.barangay_id == own_barangay)
        if report_id is not None:
            query = query.filter(PhysicalDonation.report_id == report_id)
        staff = own_barangay is None
        entries = build_entries(db, query.all(), include_donor=staff, include_cmo=staff)
        group_by_report(entries)
        if not status and not include_closed:
            entries = [e for e in entries if e["status"] not in CLOSED]
        rows = filter_and_sort(entries, status=status, handover_method=handover_method,
                               search=q, sort=sort)
        return JSONResponse(content=jsonable_encoder(rows)).body
    finally:
        db.close()


def test_no_limit_is_byte_for_byte_the_old_answer(api):
    client, t = api
    rid, other = _report(client, t), _report(client, t)
    refs = _entries(client, t, rid, 4) + _entries(client, t, other, 2)
    ok(client.post(f"/donations/entries/{refs[0]}/cancel", headers=t["donor"],
                   json={"reason": "I changed my mind"}))

    cases = [
        ("testadmin@gmail.com", "admin", {}),
        ("testadmin@gmail.com", "admin", {"include_closed": "true"}),
        ("csws.test@example.com", "csws", {"sort": "most_items", "report_id": rid}),
        ("cmo.test@example.com", "cmo", {"status": "Cancelled"}),
        ("ana.test@example.com", "brgy", {"include_closed": "true", "sort": "oldest"}),
    ]
    for email, who, params in cases:
        r = client.get("/donations/records", headers=t[who], params=params)
        assert r.status_code == 200
        assert TOTAL_HEADER.lower() not in r.headers
        old = _old_records(
            email,
            status=params.get("status"),
            report_id=params.get("report_id"),
            sort=params.get("sort", "newest"),
            include_closed=params.get("include_closed") == "true",
        )
        assert r.content == old, (who, params)


def test_pages_hold_every_entry_once_even_with_identical_timestamps(api):
    client, t = api
    rid, other = _report(client, t), _report(client, t)
    _entries(client, t, rid, 5)
    _entries(client, t, other, 4)

    # Same created_at and expires_at on every row: the order must still be
    # fixed by the final tie-breaker (the entry's first donation_id).
    same = datetime.now(timezone.utc).replace(microsecond=0)
    db = database.SessionLocal()
    db.query(PhysicalDonation).update({
        PhysicalDonation.created_at: same,
        PhysicalDonation.expires_at: same + timedelta(days=5),
    })
    db.commit()
    db.close()

    for sort in ENTRY_SORTS:
        full = ok(client.get("/donations/records", headers=t["admin"], params={"sort": sort}))
        again = ok(client.get("/donations/records", headers=t["admin"], params={"sort": sort}))
        assert [e["batch_reference"] for e in full] == [e["batch_reference"] for e in again]
        for size in (1, 2, 4):
            paged, totals = _all_pages(client, t["admin"], size, sort=sort)
            refs = [e["batch_reference"] for e in paged]
            assert refs == [e["batch_reference"] for e in full], (sort, size)
            assert len(refs) == len(set(refs)) == 9
            assert totals == {9}


def test_donation_numbers_are_kept_on_later_pages(api):
    client, t = api
    rid, other = _report(client, t), _report(client, t)
    _entries(client, t, rid, 3)
    _entries(client, t, other, 3)
    full = {e["batch_reference"]: e["entry_no"]
            for e in ok(client.get("/donations/records", headers=t["admin"]))}
    assert sorted(full.values()) == [1, 1, 2, 2, 3, 3]

    page2 = client.get("/donations/records", headers=t["admin"], params={"limit": 2, "offset": 2})
    rows = ok(page2)
    assert page2.headers[TOTAL_HEADER] == "6"
    assert len(rows) == 2
    for e in rows:
        assert e["entry_no"] == full[e["batch_reference"]]
    # Filtering by report keeps the numbers too
    by_report = ok(client.get("/donations/records", headers=t["admin"],
                              params={"report_id": other, "limit": 1, "offset": 2}))
    assert by_report[0]["entry_no"] == full[by_report[0]["batch_reference"]]


def test_filters_and_paging_together(api):
    client, t = api
    rid = _report(client, t)
    refs = _entries(client, t, rid, 5)
    ok(client.post(f"/donations/entries/{refs[1]}/cancel", headers=t["donor"],
                   json={"reason": "I changed my mind"}))

    for params in ({"status": "Pending"}, {"status": "Cancelled"},
                   {"include_closed": "true", "sort": "fewest_items"},
                   {"q": refs[3]}, {"handover_method": "Drop Off", "sort": "oldest"}):
        full = ok(client.get("/donations/records", headers=t["csws"], params=params))
        paged, totals = _all_pages(client, t["csws"], 2, **params)
        assert [e["batch_reference"] for e in paged] == [e["batch_reference"] for e in full]
        assert totals == {len(full)}, params

    assert client.get("/donations/records", headers=t["admin"], params={"limit": 0}).status_code == 422
    assert client.get("/donations/records", headers=t["admin"], params={"offset": -1}).status_code == 422
    big = client.get("/donations/records", headers=t["admin"], params={"limit": 1000})
    assert big.status_code == 200 and big.headers[TOTAL_HEADER] == "4"


def _hold_first_item(ref):
    db = database.SessionLocal()
    try:
        donation = db.query(PhysicalDonation).filter(PhysicalDonation.batch_reference == ref).first()
        cmo = db.query(User).filter(User.email == "cmo.test@example.com").one()
        db.add(DonationConfirmation(donation_id=donation.donation_id,
                                    confirmed_by_user_id=cmo.user_id,
                                    status="On Hold", notes="Waiting for papers"))
        db.commit()
    finally:
        db.close()


def test_on_hold_filter_and_counts_match_the_list(api):
    client, t = api
    rid, other = _report(client, t), _report(client, t)
    refs = _entries(client, t, rid, 4) + _entries(client, t, other, 2)
    ok(client.post(f"/donations/entries/{refs[0]}/cancel", headers=t["donor"],
                   json={"reason": "I changed my mind"}))
    _hold_first_item(refs[2])

    held = ok(client.get("/donations/records", headers=t["admin"],
                         params={"status": "On Hold", "include_closed": "true"}))
    assert [e["batch_reference"] for e in held] == [refs[2]]

    for filters in ({"include_closed": "true"}, {}, {"report_id": rid, "include_closed": "true"},
                    {"q": refs[3], "include_closed": "true"},
                    {"handover_method": "Door to Door", "include_closed": "true"}):
        counts = ok(client.get("/donations/records/counts", headers=t["admin"], params=filters))
        listed = ok(client.get("/donations/records", headers=t["admin"], params=filters))
        assert counts["all"] == len(listed), filters
        for status, n in counts["by_status"].items():
            shown = ok(client.get("/donations/records", headers=t["admin"],
                                  params={**filters, "status": status}))
            assert len(shown) == n, (filters, status)

    counts = ok(client.get("/donations/records/counts", headers=t["admin"],
                           params={"include_closed": "true", "status": "Pending"}))
    assert counts["by_status"]["Cancelled"] == 1 and counts["by_status"]["On Hold"] == 1
    assert counts["all"] == 6  # status is ignored by the counts
    assert [r["report_id"] for r in counts["reports"]] == [other, rid]
    assert ok(client.get("/donations/records/counts", headers=t["admin"]))["all"] == 5


def test_counts_keep_the_role_rules_of_the_list(api):
    client, t = api
    rid = _report(client, t)
    _entries(client, t, rid, 2)
    for who in ("admin", "csws", "cmo", "brgy"):
        counts = ok(client.get("/donations/records/counts", headers=t[who]))
        assert counts["all"] == 2, who
    for who in ("donor", "drrmo", "unit"):
        assert client.get("/donations/records/counts", headers=t[who]).status_code == 403
        assert client.get("/donations/records", headers=t[who], params={"limit": 5}).status_code == 403
    # A Barangay Receiving Representative counts only its own barangay
    other_brgy = ok(client.get("/donations/records/counts", headers=t["brgy2"]))
    assert other_brgy == {"all": 0, "items": 0, "by_status": {"On Hold": 0}, "reports": []}
    assert client.get("/donations/records/counts").status_code == 401


def test_web_build_can_read_the_total():
    import main
    client = TestClient(main.app)
    r = client.get("/", headers={"Origin": "https://nexaaid1.netlify.app"})
    assert TOTAL_HEADER.lower() in r.headers["access-control-expose-headers"].lower()


# ---------------------------------------------------------------------------
# SQL-level paging (core/m4_donation_management/entry_paging.py): with limit the database picks
# the page. Its pages put together must equal the old full answer.
# ---------------------------------------------------------------------------

def _mixed_records(client, t):
    """Entries in every state: Pending, Partly Received, Received, Expired,
    Cancelled, On Hold, Door to Door, a guest donor, an item name with % and _."""
    from tests.m4_donation_management.test_donation_batch import _pickup_slot
    rid, other = _report(client, t), _report(client, t)
    refs = _entries(client, t, rid, 6) + _entries(client, t, other, 3)
    for _ in range(2):
        b = ok(client.post("/donations/batch", headers=t["donor"], json={
            "report_id": other, "handover_method": "Door to Door",
            "pickup_address": "1 Test St, Mandaue City",
            "preferred_pickup_at": _pickup_slot().isoformat(),
            "items": [LINE, {**LINE, "quantity": 9}]}), 201)
        refs.append(b["batch_reference"])
    guest = ok(client.post("/donations/batch", json={
        "report_id": rid, "handover_method": "Drop Off",
        "items": [LINE, {"other_item_name": "50% Off_Bag", "other_item_unit": "pcs",
                         "packaging": "Box", "quantity": 3}],
        "guest_donor": {"full_name": "Gina Guest", "contact_number": "0917 123 4567",
                        "consent": True}}), 201)
    refs.append(guest["batch_reference"])

    full = {e["batch_reference"]: e for e in ok(client.get(
        "/donations/records", headers=t["admin"], params={"include_closed": "true"}))}
    # refs[1]: 2 items -> receive one (Partly Received); refs[2]: 3 items -> all (Received)
    one = full[refs[1]]["items"]
    ok(client.post(f"/donations/entries/{refs[1]}/receive", headers=t["csws"], json={
        "items": [{"donation_id": one[0]["donation_id"], "actual_quantity": 1}]}))
    ok(client.post(f"/donations/entries/{refs[2]}/receive", headers=t["csws"], json={
        "items": [{"donation_id": i["donation_id"], "actual_quantity": 1}
                  for i in full[refs[2]]["items"]]}))
    ok(client.post(f"/donations/entries/{refs[3]}/cancel", headers=t["donor"],
                   json={"reason": "I changed my mind"}))
    _hold_first_item(refs[4])
    # refs[5] is overdue: the next request marks it Expired
    db = database.SessionLocal()
    db.query(PhysicalDonation).filter(PhysicalDonation.batch_reference == refs[5]).update(
        {PhysicalDonation.expires_at: datetime.now(timezone.utc) - timedelta(days=1)})
    db.commit()
    db.close()
    return rid, other, refs


def test_sql_pages_equal_the_old_list_for_every_filter_and_sort(api):
    client, t = api
    rid, other, refs = _mixed_records(client, t)
    statuses = {e["status"] for e in ok(client.get(
        "/donations/records", headers=t["admin"], params={"include_closed": "true"}))}
    assert statuses >= {"Pending", "Partly Received", "Received", "Expired", "Cancelled"}

    filters = [
        {}, {"include_closed": "true"},
        {"status": "Pending"}, {"status": "pending"}, {"status": "Partly Received"},
        {"status": "Received"}, {"status": "Expired"}, {"status": "Cancelled"},
        {"status": "Closed"}, {"status": "On Hold"}, {"status": "On Hold", "include_closed": "true"},
        {"report_id": other, "include_closed": "true"}, {"report_id": rid},
        {"handover_method": "Door to Door"}, {"handover_method": " drop off ", "include_closed": "true"},
        {"q": "rice", "include_closed": "true"}, {"q": "GINA"}, {"q": "guest"},
        {"q": "donor test"}, {"q": "%"}, {"q": "_"}, {"q": "50% off_"}, {"q": refs[7][-6:]},
        {"q": "zzz-nothing"}, {"q": "  "},
        {"status": "Pending", "handover_method": "Drop Off", "q": "rice", "report_id": rid},
    ]
    for who in ("admin", "cmo", "brgy"):
        for f in filters:
            for sort in ENTRY_SORTS:
                params = {**f, "sort": sort}
                old = client.get("/donations/records", headers=t[who], params=params)
                assert old.status_code == 200 and TOTAL_HEADER.lower() not in old.headers
                paged, totals = _all_pages(client, t[who], 4, **params)
                # Nov 24: pages also name each confirmed delivery's receipt
                # (receipt_deliveries); the rest is the old list exactly.
                for e in paged:
                    e.pop("receipt_deliveries", None)
                assert paged == old.json(), (who, params)
                assert totals == {len(old.json())}, (who, params)


def test_sql_counts_match_the_list_for_every_role(api):
    client, t = api
    rid, other, refs = _mixed_records(client, t)
    for who in ("admin", "csws", "cmo", "brgy"):
        for f in ({}, {"include_closed": "true"}, {"report_id": rid, "include_closed": "true"},
                  {"q": "gina", "include_closed": "true"}, {"handover_method": "Door to Door"}):
            counts = ok(client.get("/donations/records/counts", headers=t[who], params=f))
            listed = ok(client.get("/donations/records", headers=t[who], params=f))
            assert counts["all"] == len(listed)
            assert counts["items"] == sum(e["total_items"] for e in listed)
            for status, n in counts["by_status"].items():
                shown = ok(client.get("/donations/records", headers=t[who],
                                      params={**f, "status": status, "include_closed": "true"}))
                assert len(shown) == n, (who, f, status)
    assert ok(client.get("/donations/records/counts", headers=t["admin"]))["by_status"]["On Hold"] == 1
    assert ok(client.get("/donations/records/counts", headers=t["brgy"]))["by_status"]["On Hold"] == 0


def test_a_page_builds_only_its_own_entries(api, monkeypatch):
    """The point of SQL paging: one page never builds every entry."""
    import core.m5_inventory.receiving_routes as routes
    import core.m4_donation_management.entry_paging as paging
    client, t = api
    rid = _report(client, t)
    _entries(client, t, rid, 12)

    built = []
    real = paging.build_entries

    def spy(db, rows, **kw):
        built.append({r.batch_reference for r in rows})
        return real(db, rows, **kw)

    def full_build(*a, **kw):
        raise AssertionError("the paged request built the full list")

    monkeypatch.setattr(paging, "build_entries", spy)
    monkeypatch.setattr(routes, "build_entries", full_build)
    r = client.get("/donations/records", headers=t["admin"], params={"limit": 5, "offset": 5})
    assert len(ok(r)) == 5 and r.headers[TOTAL_HEADER] == "12"
    assert built == [built[0]] and len(built[0]) == 5
    ok(client.get("/donations/records/counts", headers=t["admin"]))
    assert len(built) == 1  # the counts build no entries at all
