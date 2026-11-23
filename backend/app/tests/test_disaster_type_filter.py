"""
NF-001 (T2): the Administrator's records screen filters every tab by
disaster type, in the database, one page at a time.

- Donations: GET /donations/records (+ /counts, + /per-report)
- Per report: GET /cmo/report-summaries (same numbers as /cmo/dashboard)
- Deliveries: GET /deliveries/ and /deliveries/counts
- Logistics: GET /logistics/requests (delivery requests and pickup runs)

Each: filter by type, unknown type = empty (not an error), no param = as
before, filter + paging totals, roles unchanged.
"""
from datetime import datetime, timezone

from core import database
from core.pagination import TOTAL_HEADER
from models.delivery import Delivery
from models.logistics_request_model import LogisticsRequest
from models.report import DisasterType
from models.user_rbac_model import User
from tests.test_donation_batch import LINE
from tests.test_role_flows import api, ok  # noqa: F401  (fixture)

FLOOD, TYPHOON, UNKNOWN = 1, 2, 999


def _setup(client, t):
    """2 Flood reports and 1 Typhoon report, with donations, received and
    acknowledged items, deliveries and logistics requests on each type."""
    db = database.SessionLocal()
    db.add(DisasterType(disaster_type_id=TYPHOON, type_name="Typhoon"))
    db.commit()
    db.close()

    def report(type_id):
        rid = ok(client.post("/reports/", headers=t["unit"], json={
            "disaster_type_id": type_id, "barangay_id": 1, "estimated_quantity": 200}), 201)["report_id"]
        ok(client.post(f"/reports/{rid}/validate", headers=t["admin"], json={}))
        return rid

    flood1, flood2, typhoon = report(FLOOD), report(FLOOD), report(TYPHOON)
    refs = {}
    for rid, n in ((flood1, 4), (flood2, 3), (typhoon, 5)):
        refs[rid] = [ok(client.post("/donations/batch", headers=t["donor"], json={
            "report_id": rid, "handover_method": "Drop Off",
            "items": [LINE, {**LINE, "quantity": 5}]}), 201)["batch_reference"] for _ in range(n)]

    # Received + acknowledged items for the per-report summaries
    for rid in (flood1, typhoon):
        for ref, decision in ((refs[rid][0], "Acknowledged"), (refs[rid][1], None)):
            entry = ok(client.get("/donations/records", headers=t["csws"], params={"q": ref}))[0]
            ok(client.post(f"/donations/entries/{ref}/receive", headers=t["csws"], json={
                "items": [{"donation_id": i["donation_id"], "actual_quantity": i["quantity"]}
                          for i in entry["items"]]}))
            if decision:
                ok(client.post(f"/cmo/entries/{ref}/decide", headers=t["cmo"],
                               json={"status": decision}))

    # Deliveries and logistics requests, written directly (their own flows
    # need stock and trips; only the filtering is under test here).
    db = database.SessionLocal()
    csws = db.query(User).filter(User.email == "csws.test@example.com").one()
    now = datetime.now(timezone.utc)
    deliveries = {}
    for rid, statuses in ((flood1, ["Preparing", "In Transit"]), (flood2, ["Delivered"]),
                          (typhoon, ["Preparing", "Confirmed", "In Transit"])):
        for st in statuses:
            d = Delivery(report_id=rid, destination_barangay_id=1, handled_by_user_id=csws.user_id,
                         status=st, delivery_date=now)
            db.add(d)
            db.flush()
            deliveries.setdefault(rid, []).append(d.delivery_id)
    for rid, ids in deliveries.items():
        for did in ids:
            db.add(LogisticsRequest(delivery_id=did, requested_by_user_id=csws.user_id,
                                    status="Accepted", request_type="Delivery"))
    # Pickup runs: one Typhoon-only, one mixing a Flood and a Typhoon donation
    db.add(LogisticsRequest(requested_by_user_id=csws.user_id, status="Pending",
                            request_type="Pickup", pickup_date=now.date(), pickup_batches=refs[typhoon][3]))
    db.add(LogisticsRequest(requested_by_user_id=csws.user_id, status="Pending",
                            request_type="Pickup", pickup_date=now.date(),
                            pickup_batches=f"{refs[flood2][2]},{refs[typhoon][4]}"))
    db.commit()
    db.close()
    return flood1, flood2, typhoon, refs


def _pages(client, headers, path, size, **params):
    rows, totals, offset = [], set(), 0
    while True:
        r = client.get(path, headers=headers, params={**params, "limit": size, "offset": offset})
        page = ok(r)
        totals.add(int(r.headers[TOTAL_HEADER]))
        rows += page
        if len(page) < size:
            return rows, totals
        offset += size


def test_donation_records_filter_by_disaster_type(api):
    client, t = api
    flood1, flood2, typhoon, refs = _setup(client, t)
    flood_refs = set(refs[flood1] + refs[flood2])

    for who in ("admin", "csws", "cmo", "brgy"):
        everything = ok(client.get("/donations/records", headers=t[who], params={"include_closed": "true"}))
        assert len(everything) == 12
        old = ok(client.get("/donations/records", headers=t[who],
                            params={"include_closed": "true", "disaster_type_id": FLOOD}))
        assert {e["batch_reference"] for e in old} == flood_refs
        paged, totals = _pages(client, t[who], "/donations/records", 3,
                               include_closed="true", disaster_type_id=FLOOD)
        for e in paged:   # Nov 24: pages also name confirmed deliveries' receipts
            e.pop("receipt_deliveries", None)
        assert paged == old and totals == {7}
        assert ok(client.get("/donations/records", headers=t[who],
                             params={"disaster_type_id": UNKNOWN, "limit": 20})) == []

    counts = ok(client.get("/donations/records/counts", headers=t["admin"],
                           params={"include_closed": "true", "disaster_type_id": TYPHOON}))
    assert counts["all"] == 5
    assert [r["report_id"] for r in counts["reports"]] == [typhoon]
    # "Donation N" numbers are the report's own, filter or not
    assert sorted(e["entry_no"] for e in paged if e["report_id"] == flood2) == [1, 2, 3]


def test_per_report_view_is_grouped_and_paged_in_sql(api):
    client, t = api
    flood1, flood2, typhoon, refs = _setup(client, t)
    rows, totals = _pages(client, t["admin"], "/donations/records/per-report", 2)
    assert [r["report_id"] for r in rows] == [typhoon, flood2, flood1] and totals == {3}
    assert {r["report_id"]: r["total_entries"] for r in rows} == {flood1: 4, flood2: 3, typhoon: 5}
    one = next(r for r in rows if r["report_id"] == flood1)
    assert one["by_status"] == {"Pending": 2, "Received": 1, "Confirmed": 1}
    flood_only = ok(client.get("/donations/records/per-report", headers=t["admin"],
                               params={"disaster_type_id": FLOOD}))
    assert [r["report_id"] for r in flood_only] == [flood2, flood1]
    assert ok(client.get("/donations/records/per-report", headers=t["admin"],
                         params={"disaster_type_id": UNKNOWN})) == []
    assert client.get("/donations/records/per-report", headers=t["drrmo"]).status_code == 403


def test_report_summaries_match_the_dashboard_and_filter(api):
    client, t = api
    flood1, flood2, typhoon, refs = _setup(client, t)
    dashboard = ok(client.get("/cmo/dashboard", headers=t["cmo"]))["per_report"]
    summaries, totals = _pages(client, t["admin"], "/cmo/report-summaries", 1)
    by_id = lambda rows: {r["report_id"]: r for r in rows}  # noqa: E731
    assert by_id(summaries) == by_id(dashboard) and totals == {2}
    assert [r["report_id"] for r in summaries] == [typhoon, flood1]  # newest first
    flood = ok(client.get("/cmo/report-summaries", headers=t["cmo"],
                          params={"disaster_type_id": FLOOD}))
    assert [r["report_id"] for r in flood] == [flood1]
    assert flood[0]["confirmed_count"] == 2 and flood[0]["pending_count"] == 2
    assert ok(client.get("/cmo/report-summaries", headers=t["cmo"],
                         params={"disaster_type_id": UNKNOWN})) == []
    for who in ("csws", "donor", "drrmo", "brgy"):
        assert client.get("/cmo/report-summaries", headers=t[who]).status_code == 403


def test_deliveries_filter_by_disaster_type_and_send_the_total(api):
    client, t = api
    _setup(client, t)
    old = client.get("/deliveries/", headers=t["admin"])
    assert len(ok(old)) == 6 and old.headers[TOTAL_HEADER] == "6"
    rows, totals = _pages(client, t["admin"], "/deliveries/", 2, disaster_type_id=TYPHOON)
    assert len(rows) == 3 and totals == {3}
    assert len({r["delivery_id"] for r in rows}) == 3
    in_transit = ok(client.get("/deliveries/", headers=t["admin"],
                               params={"disaster_type_id": FLOOD, "status": "In Transit"}))
    assert len(in_transit) == 1
    counts = ok(client.get("/deliveries/counts", headers=t["admin"], params={"disaster_type_id": FLOOD}))
    assert counts["total"] == 3 and counts["Preparing"] == 1 and counts["Delivered"] == 1
    assert ok(client.get("/deliveries/", headers=t["admin"], params={"disaster_type_id": UNKNOWN})) == []
    # skip (older apps) still works
    assert len(ok(client.get("/deliveries/", headers=t["admin"], params={"skip": 4}))) == 2


def test_logistics_requests_filter_by_type_and_stage(api):
    client, t = api
    flood1, flood2, typhoon, refs = _setup(client, t)
    everything = ok(client.get("/logistics/requests", headers=t["csws"]))
    assert len(everything) == 8
    assert TOTAL_HEADER.lower() not in client.get("/logistics/requests", headers=t["csws"]).headers

    typhoon_rows, totals = _pages(client, t["admin"], "/logistics/requests", 2, disaster_type_id=TYPHOON)
    # 3 Typhoon deliveries + both pickup runs (the mixed one has a Typhoon donation)
    assert totals == {5} and len(typhoon_rows) == 5
    assert sum(1 for r in typhoon_rows if r["request_type"] == "Pickup") == 2
    flood_rows = ok(client.get("/logistics/requests", headers=t["admin"],
                               params={"disaster_type_id": FLOOD}))
    assert len(flood_rows) == 4  # 3 Flood deliveries + the mixed pickup run

    # The stage filter returns exactly the rows whose "stage" is that value
    for stage in ("Pending", "Accepted", "In Transit", "Completed", "Declined"):
        filtered = ok(client.get("/logistics/requests", headers=t["admin"], params={"stage": stage}))
        assert sorted(r["request_id"] for r in filtered) == sorted(
            r["request_id"] for r in everything if r["stage"] == stage), stage
    assert ok(client.get("/logistics/requests", headers=t["admin"],
                         params={"disaster_type_id": UNKNOWN})) == []
    assert client.get("/logistics/requests", headers=t["drrmo"]).status_code == 403
