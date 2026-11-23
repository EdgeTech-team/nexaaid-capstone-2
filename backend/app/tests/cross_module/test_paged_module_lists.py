"""
NF-003 (T3): Dave's other module lists page and filter on the server.

- Module 6.1 CMO queue / On hold: GET /cmo/entries/pending
- Module 6.1 CMO History:        GET /cmo/entries/acknowledged
- Module 7.2 DRRMO requests:     GET /drrmo/requests

Each: no params = the old answer (no header); with filters or limit the
database filters, sorts and pages, and the result matches the old answer
filtered the way the app used to filter it.
"""
from core.shared.pagination import TOTAL_HEADER
from tests.m4_donation_management.test_donation_batch import LINE, _report
from tests.shared.test_pagination import _hold_first_item  # noqa: F401  (helper)
from tests.m1_user_management.test_role_flows import api, ok  # noqa: F401  (fixture)


def _cmo_data(client, t):
    """Received entries (some On Hold, some under review) and acknowledged
    ones, from a donor and a guest, over two reports."""
    rid, other = _report(client, t), _report(client, t)
    refs = []
    for i in range(9):
        refs.append(ok(client.post("/donations/batch", headers=t["donor"], json={
            "report_id": rid if i % 2 else other, "handover_method": "Drop Off",
            "items": [LINE, {**LINE, "quantity": 3 + i}]}), 201)["batch_reference"])
    refs.append(ok(client.post("/donations/batch", json={
        "report_id": rid, "handover_method": "Drop Off",
        "items": [{"other_item_name": "Canned Tuna", "other_item_unit": "cans",
                   "packaging": "Box", "quantity": 6}],
        "guest_donor": {"full_name": "Gina Guest", "contact_number": "0917 123 4567",
                        "consent": True}}), 201)["batch_reference"])
    for ref in refs:
        entry = ok(client.get("/donations/records", headers=t["csws"], params={"q": ref}))[0]
        ok(client.post(f"/donations/entries/{ref}/receive", headers=t["csws"], json={
            "items": [{"donation_id": i["donation_id"], "actual_quantity": i["quantity"]}
                      for i in entry["items"]]}))
    for ref in refs[:3]:
        ok(client.post(f"/cmo/entries/{ref}/decide", headers=t["cmo"], json={"status": "Acknowledged"}))
    for ref in refs[3:5]:
        ok(client.post(f"/cmo/entries/{ref}/decide", headers=t["cmo"],
                       json={"status": "On Hold", "notes": "Waiting for papers"}))
    ok(client.post(f"/cmo/entries/{refs[5]}/decide", headers=t["cmo"],
                   json={"status": "Pending Review", "notes": "Checking the count"}))
    return rid, other, refs


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


def _app_matches(e, q):
    """The CMO screens' old search (cmo_screens.dart _matches)."""
    text = " ".join(str(x) for x in [
        e["batch_reference"], e["donor"], e["barangay"], e["disaster_type"], e["report_label"],
        *[i["item_name"] for i in e["items"]]] if x is not None).lower()
    return q.strip().lower() in text


def _refs(rows):
    return [e["batch_reference"] for e in rows]


def test_cmo_queue_filters_sorts_and_pages_like_the_app_did(api):
    client, t = api
    rid, other, refs = _cmo_data(client, t)
    old = client.get("/cmo/entries/pending", headers=t["cmo"])
    assert TOTAL_HEADER.lower() not in old.headers
    old = ok(old)
    assert len(old) == 7
    dashboard = ok(client.get("/cmo/dashboard", headers=t["cmo"]))
    assert dashboard["on_hold_entries"] == sum(1 for e in old if e["cmo_decision"] == "On Hold") == 2

    for params, keep in [
        ({}, lambda e: True),
        ({"on_hold": "true"}, lambda e: e["cmo_decision"] == "On Hold"),
        ({"on_hold": "false"}, lambda e: e["cmo_decision"] != "On Hold"),
        ({"q": "gina"}, lambda e: _app_matches(e, "gina")),
        ({"q": "tuna"}, lambda e: _app_matches(e, "tuna")),
        ({"q": f"#{rid} flood"}, lambda e: _app_matches(e, f"#{rid} flood")),
        ({"q": "donor test"}, lambda e: _app_matches(e, "donor test")),
        ({"q": refs[6][-5:].lower()}, lambda e: _app_matches(e, refs[6][-5:])),
        ({"q": "50%_"}, lambda e: False),
        ({"barangay_id": 1}, lambda e: e["barangay"] == "Barangay Test"),
        ({"barangay_id": 2}, lambda e: False),
        ({"disaster_type_id": 1, "on_hold": "false"}, lambda e: e["cmo_decision"] != "On Hold"),
    ]:
        for newest in ("true", "false"):
            paged, totals = _pages(client, t["cmo"], "/cmo/entries/pending", 2, newest=newest, **params)
            expected = [e for e in old if keep(e)]
            assert sorted(_refs(paged)) == sorted(_refs(expected)), (params, newest)
            assert totals == {len(expected)}, (params, newest)
            times = [e["received_at"] for e in paged]
            assert times == sorted(times, reverse=newest == "true"), (params, newest)
            # Every field is the one the old answer had
            by_ref = {e["batch_reference"]: e for e in old}
            assert all(e == by_ref[e["batch_reference"]] for e in paged)


def test_cmo_history_filters_and_pages(api):
    client, t = api
    rid, other, refs = _cmo_data(client, t)
    old = ok(client.get("/cmo/entries/acknowledged", headers=t["cmo"]))
    assert sorted(_refs(old)) == sorted(refs[:3])
    paged, totals = _pages(client, t["cmo"], "/cmo/entries/acknowledged", 2)
    assert sorted(_refs(paged)) == sorted(refs[:3]) and totals == {3}
    times = [e["acknowledged_at"] for e in paged]
    assert times == sorted(times, reverse=True)
    one = ok(client.get("/cmo/entries/acknowledged", headers=t["cmo"],
                        params={"q": refs[1], "limit": 20}))
    assert _refs(one) == [refs[1]]
    assert ok(client.get("/cmo/entries/acknowledged", headers=t["cmo"],
                         params={"disaster_type_id": 999})) == []
    for who in ("admin", "csws", "donor", "drrmo", "brgy"):
        assert client.get("/cmo/entries/acknowledged", headers=t[who],
                          params={"limit": 5}).status_code == 403
        assert client.get("/cmo/entries/pending", headers=t[who],
                          params={"limit": 5}).status_code == 403


def test_drrmo_requests_page_after_the_priority_sort(api):
    from datetime import datetime, timezone

    from core.shared import database
    from core.m8_delivery_tracking.delivery_model import Delivery
    from core.m7_logistics_support.logistics_request_model import LogisticsRequest
    from core.m1_user_management.user_rbac_model import User

    client, t = api
    rid = _report(client, t)
    db = database.SessionLocal()
    csws = db.query(User).filter(User.email == "csws.test@example.com").one()
    for st in ("Pending", "Pending", "Accepted", "Declined", "Pending"):
        d = Delivery(report_id=rid, destination_barangay_id=1, handled_by_user_id=csws.user_id,
                     status="Preparing", delivery_date=datetime.now(timezone.utc))
        db.add(d)
        db.flush()
        db.add(LogisticsRequest(delivery_id=d.delivery_id, requested_by_user_id=csws.user_id,
                                status=st, request_type="Delivery"))
    db.commit()
    db.close()

    old = client.get("/drrmo/requests", headers=t["drrmo"])
    assert TOTAL_HEADER.lower() not in old.headers
    old = ok(old)
    paged, totals = _pages(client, t["drrmo"], "/drrmo/requests", 2)
    assert paged == old and totals == {5}
    pending, totals = _pages(client, t["drrmo"], "/drrmo/requests", 2, status="Pending")
    assert [r["request_id"] for r in pending] == [r["request_id"] for r in old if r["status"] == "Pending"]
    assert totals == {3}
    assert client.get("/drrmo/requests", headers=t["cmo"], params={"limit": 2}).status_code == 403


def test_drrmo_stage_filter_and_counts_match_the_rows(api):
    from datetime import datetime, timezone

    from core.shared import database
    from core.m8_delivery_tracking.delivery_model import Delivery
    from core.m7_logistics_support.logistics_request_model import LogisticsRequest
    from core.m1_user_management.user_rbac_model import User

    client, t = api
    rid = _report(client, t)
    db = database.SessionLocal()
    csws = db.query(User).filter(User.email == "csws.test@example.com").one()
    for req_status, delivery_status in (("Pending", "Preparing"), ("Accepted", "Preparing"),
                                        ("Accepted", "In Transit"), ("Accepted", "Delivered"),
                                        ("Completed", "Confirmed"), ("Declined", "Preparing"),
                                        ("Cancelled", "Cancelled")):
        d = Delivery(report_id=rid, destination_barangay_id=1, handled_by_user_id=csws.user_id,
                     status=delivery_status, delivery_date=datetime.now(timezone.utc))
        db.add(d)
        db.flush()
        db.add(LogisticsRequest(delivery_id=d.delivery_id, requested_by_user_id=csws.user_id,
                                status=req_status, request_type="Delivery"))
    db.commit()
    db.close()

    everything = ok(client.get("/drrmo/requests", headers=t["drrmo"]))
    counts = ok(client.get("/drrmo/requests/counts", headers=t["drrmo"]))
    assert counts == {"Pending": 1, "Accepted": 1, "In Transit": 2, "Completed": 1,
                      "Declined": 1, "Cancelled": 1}
    for stage, n in counts.items():
        rows = ok(client.get("/drrmo/requests", headers=t["drrmo"], params={"stage": stage}))
        assert sorted(r["request_id"] for r in rows) == sorted(
            r["request_id"] for r in everything if r["stage"] == stage), stage
        assert len(rows) == n
    one = everything[3]["request_id"]
    assert [r["request_id"] for r in ok(client.get(
        "/drrmo/requests", headers=t["drrmo"], params={"request_id": one}))] == [one]
    assert client.get("/drrmo/requests/counts", headers=t["csws"]).status_code == 403

    # Phase 6 search on the server (every page): request / delivery number
    # ("#12" or "12"), or text in the barangay / report name.
    target = everything[2]
    for q in (f"#{target['request_id']}", str(target["delivery_id"])):
        hits = ok(client.get("/drrmo/requests", headers=t["drrmo"], params={"q": q}))
        assert target["request_id"] in [r["request_id"] for r in hits], q
    word = (target["report_label"] or target["destination"]).split()[-1]
    hits = ok(client.get("/drrmo/requests", headers=t["drrmo"],
                         params={"q": word.upper(), "limit": 2}))
    assert hits and all(word.lower() in f"{r['destination']} {r['report_label']}".lower()
                        or str(r["request_id"]) == word for r in hits)
    assert ok(client.get("/drrmo/requests", headers=t["drrmo"],
                         params={"q": "no such place zzz"})) == []
