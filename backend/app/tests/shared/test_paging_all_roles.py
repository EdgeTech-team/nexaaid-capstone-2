"""
NF-003 (all roles): pages of 20 for the Admin's account lists and every
role's inbox. Each paged list must hold exactly the rows of the old full
list, in the same order, with the total in X-Total-Count; without `limit`
the old answer is unchanged (installed APKs).
"""
from datetime import datetime, timedelta, timezone

from core.shared import database
from core.m1_user_management.auth import hash_password
from core.notifications.notification_model import Notification
from core.m1_user_management.organization_model import Organization
from core.m1_user_management.user_rbac_model import User
from tests.m1_user_management.test_role_flows import PASSWORD, api, ok  # noqa: F401  (fixture)


def _pages(client, headers, path, size=3, **params):
    rows, offset = [], 0
    while True:
        r = client.get(path, headers=headers, params={**params, "limit": size, "offset": offset})
        assert r.status_code == 200, r.text
        page = r.json()
        rows += page
        offset += len(page)
        if len(page) < size:
            return rows, int(r.headers["x-total-count"])


def _donors_and_orgs(n=7):
    db = database.SessionLocal()
    base = datetime(2026, 10, 1, tzinfo=timezone.utc)
    for i in range(n):
        db.add(User(first_name=f"Donor{i}", last_name="Cruz" if i % 2 else "Reyes",
                    contact_number=f"0917000{i:04d}", email=f"donor{i}@example.com",
                    password_hash=hash_password(PASSWORD), role_id=2,
                    created_at=base + timedelta(days=i % 3),
                    reviewed_at=base if i % 3 == 0 else None,
                    is_active=i != 4))
        db.add(Organization(org_name=f"Org {chr(70 - i)}", organization_type="NGO", contact_person="Ana Cruz",
                            contact_email=f"org{i}@example.com", status="Approved",
                            created_at=base + timedelta(days=i), reviewed_at=base if i % 2 else None))
    db.commit()
    db.close()


def test_accounts_page_like_the_full_list(api):
    client, t = api
    _donors_and_orgs()
    for params in ({}, {"active": "true"}, {"active": "false"}, {"role": "Individual Donor"}, {"q": "cruz"}):
        full = ok(client.get("/admin/users", headers=t["admin"], params=params))
        paged, total = _pages(client, t["admin"], "/admin/users", **params)
        assert [u["user_id"] for u in paged] == [u["user_id"] for u in full], params
        assert total == len(full)
    assert "x-total-count" not in client.get("/admin/users", headers=t["admin"]).headers


def test_registrations_filters_sort_and_pages(api):
    client, t = api
    _donors_and_orgs()
    everything, total = _pages(client, t["admin"], "/admin/registrations", sort="name")
    orgs = ok(client.get("/admin/organizations", headers=t["admin"]))
    donors = ok(client.get("/admin/users", headers=t["admin"], params={"role": "Individual Donor"}))
    assert total == len(orgs) + len(donors)
    assert [r["name"].lower() for r in everything] == sorted(r["name"].lower() for r in everything)

    newest, _ = _pages(client, t["admin"], "/admin/registrations", sort="newest")
    dates = [r["created_at"] for r in newest]
    assert dates == sorted(dates, reverse=True)
    assert len({(r["type"], r["id"]) for r in newest}) == len(newest)  # no repeats

    not_reviewed, _ = _pages(client, t["admin"], "/admin/registrations", review="not")
    assert not_reviewed and not any(r["reviewed"] for r in not_reviewed)
    only_orgs, _ = _pages(client, t["admin"], "/admin/registrations", kind="orgs")
    assert {r["type"] for r in only_orgs} == {"org"} and len(only_orgs) == len(orgs)
    found, _ = _pages(client, t["admin"], "/admin/registrations", q="donor3 reyes".split()[0])
    assert [r["email"] for r in found] == ["donor3@example.com"]

    one = ok(client.get("/admin/registrations", headers=t["admin"],
                        params={"focus_type": "org", "focus_id": orgs[0]["organization_id"]}))
    assert [(r["type"], r["id"]) for r in one] == [("org", orgs[0]["organization_id"])]

    counts = ok(client.get("/admin/registrations/counts", headers=t["admin"]))
    assert counts["all"] == total
    assert counts["reviewed"] + counts["not_reviewed"] == total
    assert counts["not_reviewed"] == len(_pages(client, t["admin"], "/admin/registrations", review="not")[0])


def test_registrations_admin_only_and_bad_values(api):
    client, t = api
    for who in ("donor", "csws", "cmo"):
        assert client.get("/admin/registrations", headers=t[who]).status_code == 403
        assert client.get("/admin/registrations/counts", headers=t[who]).status_code == 403
    for bad in ({"review": "maybe"}, {"kind": "pets"}, {"sort": "random"}):
        assert client.get("/admin/registrations", headers=t["admin"], params=bad).status_code == 422


def test_inbox_pages_with_a_total(api):
    client, t = api
    db = database.SessionLocal()
    donor = db.query(User).filter(User.email == "maria.test@example.com").first() or \
        db.query(User).filter(User.role_id == 2).first()
    for i in range(45):
        db.add(Notification(user_id=donor.user_id, title=f"Note {i}", message="m",
                            type="info", is_read=i % 2 == 0))
    email = donor.email
    db.commit()
    db.close()
    headers = {"Authorization": "Bearer " + ok(client.post("/token", data={
        "username": email, "password": PASSWORD}))["access_token"]}
    first = client.get("/notifications/", headers=headers, params={"limit": 20, "offset": 0})
    total = int(first.headers["x-total-count"])
    assert total >= 45
    seen = []
    for offset in range(0, total, 20):
        seen += ok(client.get("/notifications/", headers=headers,
                              params={"limit": 20, "offset": offset}))["items"]
    ids = [n["notification_id"] for n in seen]
    assert len(ids) == total == len(set(ids))


def test_requests_for_one_page_of_deliveries_only(api):
    from core.m8_delivery_tracking.delivery_model import Delivery
    from core.m7_logistics_support.logistics_request_model import LogisticsRequest
    from tests.m4_donation_management.test_donation_batch import _report

    client, t = api
    rid = _report(client, t)
    db = database.SessionLocal()
    csws = db.query(User).filter(User.email == "csws.test@example.com").one()
    ids = []
    for _ in range(4):
        d = Delivery(report_id=rid, destination_barangay_id=1, handled_by_user_id=csws.user_id,
                     status="Preparing", delivery_date=datetime.now(timezone.utc))
        db.add(d)
        db.flush()
        db.add(LogisticsRequest(delivery_id=d.delivery_id, requested_by_user_id=csws.user_id,
                                status="Pending", request_type="Delivery"))
        ids.append(d.delivery_id)
    db.commit()
    db.close()
    some = f"{ids[0]},{ids[2]}"
    for who, path in (("csws", "/logistics/requests"), ("drrmo", "/drrmo/requests")):
        rows = ok(client.get(path, headers=t[who], params={"delivery_ids": some}))
        assert sorted(r["delivery_id"] for r in rows) == [ids[0], ids[2]], path
        assert client.get(path, headers=t[who], params={"delivery_ids": "1,abc"}).status_code == 422
        too_many = ",".join(str(i) for i in range(101))
        assert client.get(path, headers=t[who], params={"delivery_ids": too_many}).status_code == 422


def _validated(client, t, n=26):
    from decimal import Decimal

    from core.m2_disaster_reporting.report_model import DisasterReport, ReportFulfillment
    db = database.SessionLocal()
    unit = db.query(User).filter(User.email == "rico.test@example.com").one()
    for i in range(n):
        r = DisasterReport(user_id=unit.user_id, disaster_type_id=1, barangay_id=1 + i % 2, source="Web",
                           status="Validated", affected_families=(i * 5) % 13,
                           priority_level=["Critical", "High", "Medium", "Low", None][i % 5],
                           description=f"needs rice {i}" if i % 3 == 0 else "water")
        db.add(r)
        db.flush()
        if i % 4:
            db.add(ReportFulfillment(report_id=r.report_id, total_items_needed=100,
                                     total_items_delivered=0,
                                     fulfillment_percentage=Decimal([0, 30, 100, 65][i % 4])))
    db.commit()
    db.close()


def test_donor_feed_pages_match_the_lookups_rows(api):
    client, t = api
    _validated(client, t)
    lookups = ok(client.get("/lookups", headers=t["donor"]))["validated_reports"]
    for params in ({}, {"quick": "urgent"}, {"quick": "needs"}, {"quick": "fulfilled"},
                   {"done": "false"}, {"q": "rice"}, {"priority": "High"}, {"sort": "newest"},
                   {"sort": "most_families"}):
        got, total = _pages(client, t["donor"], "/public/reports/feed", size=7, **params)
        assert total == len(got)
        assert len({r["id"] for r in got}) == len(got)
        by_id = {r["id"]: r for r in lookups}
        # Same rows as /lookups (same shape), only filtered and ordered.
        for r in got:
            assert r == by_id[r["id"]], params
    urgent, _ = _pages(client, t["donor"], "/public/reports/feed", quick="urgent")
    assert urgent and all(r["priority_level"] in ("Critical", "High") for r in urgent)
    fulfilled, _ = _pages(client, t["donor"], "/public/reports/feed", quick="fulfilled")
    assert all(r["fulfillment_percentage"] >= 100 for r in fulfilled)
    newest, _ = _pages(client, t["donor"], "/public/reports/feed", sort="newest")
    assert [r["id"] for r in newest] == sorted((r["id"] for r in newest), reverse=True)
    counts = ok(client.get("/public/reports/feed/counts"))
    assert counts["all"] == len(_pages(client, t["donor"], "/public/reports/feed")[0])
    assert counts["urgent"] == len(urgent)


def test_guests_get_the_feed_without_login(api):
    client, t = api
    _validated(client, t, n=5)
    r = client.get("/public/reports/feed", params={"limit": 20, "offset": 0})
    assert r.status_code == 200 and int(r.headers["x-total-count"]) >= 5
    assert client.get("/public/reports/feed", params={"sort": "bogus"}).status_code == 422
    assert client.get("/public/reports/feed", params={"quick": "maybe"}).status_code == 422


def test_my_giving_pages_hold_the_same_entries(api):
    from tests.m4_donation_management.test_donation_batch import LINE, _report

    client, t = api
    rid = _report(client, t)
    rid2 = _report(client, t)
    for i in range(23):
        ok(client.post("/donations/batch", headers=t["donor"], json={
            "report_id": rid if i % 3 else rid2, "handover_method": "Drop Off",
            "items": [LINE] * (1 + i % 2)}), 201)
    mine = ok(client.get("/donations/mine", headers=t["donor"]))["entries"]
    got, total = _pages(client, t["donor"], "/donations/mine/entries", size=7)
    assert total == len(mine) == 23
    assert [e["batch_reference"] for e in got] == [e["batch_reference"] for e in mine]
    assert got[0] == mine[0]  # the same rows as /donations/mine

    two_items, _ = _pages(client, t["donor"], "/donations/mine/entries", sort="most_items")
    assert [e["total_items"] for e in two_items] == sorted((e["total_items"] for e in mine), reverse=True)
    only_rid2, _ = _pages(client, t["donor"], "/donations/mine/entries", report_id=rid2)
    assert len(only_rid2) == sum(1 for e in mine if e["report_id"] == rid2)
    pending, _ = _pages(client, t["donor"], "/donations/mine/entries", status="Pending")
    assert len(pending) == 23
    waiting, _ = _pages(client, t["donor"], "/donations/mine/entries", view="waiting")
    assert len(waiting) == 23

    counts = ok(client.get("/donations/mine/entries/counts", headers=t["donor"]))
    assert counts["all"] == 23 and counts["by_status"]["Pending"] == 23
    assert counts["summary"] == {"entries": 23, "waiting": 23, "on_the_way": 0}
    assert {r["report_id"] for r in counts["reports"]} == {rid, rid2}
    assert len(counts["supported_reports"]) == 2

    # Another account sees none of them.
    assert ok(client.get("/donations/mine/entries/counts", headers=t["cmo"]))["all"] == 0
    assert client.get("/donations/mine/entries", headers=t["donor"], params={"sort": "x"}).status_code == 422


def test_receive_tabs_page_the_old_data(api):
    from tests.m4_donation_management.test_donation_batch import LINE, _report

    client, t = api
    rids = [_report(client, t) for _ in range(3)]
    manila = timezone(timedelta(hours=8))
    slot = datetime.now(manila) + timedelta(days=1)
    while slot.isoweekday() > 5:
        slot += timedelta(days=1)
    slot = slot.replace(hour=10, minute=0, second=0, microsecond=0).isoformat()
    refs = []
    for i in range(25):
        b = ok(client.post("/donations/batch", headers=t["donor"], json={
            "report_id": rids[i % 3], "handover_method": "Drop Off" if i % 4 else "Door to Door",
            "pickup_address": "1 Test St, Mandaue City", "preferred_pickup_at": slot,
            "items": [LINE]}), 201)
        refs.append(b["batch_reference"])
    # CSWS receives a few, so the Received tab and the inventory have rows.
    for ref in refs[:4]:
        entry = ok(client.get("/donations/records", headers=t["csws"],
                              params={"q": ref, "include_closed": "true"}))[0]
        ok(client.post(f"/donations/entries/{ref}/receive", headers=t["csws"], json={
            "items": [{"donation_id": i["donation_id"], "actual_quantity": i["quantity"]}
                      for i in entry["items"]]}))

    old_pending = ok(client.get("/donations/entries", headers=t["csws"], params={"pending_only": "true"}))
    pending, total = _pages(client, t["csws"], "/donations/receive-queue", size=6, tab="pending")
    assert total == old_pending["total_entries"] == 21
    assert {e["batch_reference"] for e in pending} == {
        e["batch_reference"] for g in old_pending["reports"] for e in g["entries"]}
    # A page's entries of one report stay together (grouped like the cards).
    seen, last = [], None
    for e in pending:
        if e["report_id"] != last:
            assert e["report_id"] not in seen, "a report's entries are split up"
            seen.append(e["report_id"])
            last = e["report_id"]
    assert all("report_waiting" in e and "report_label" in e for e in pending)

    received, rtotal = _pages(client, t["csws"], "/donations/receive-queue", size=3, tab="received")
    assert rtotal == 4 and {e["batch_reference"] for e in received} == set(refs[:4])
    stock, stotal = _pages(client, t["csws"], "/donations/receive-queue", tab="inventory")
    assert stotal == len(ok(client.get("/donations/inventory", headers=t["csws"])))

    door, _ = _pages(client, t["csws"], "/donations/receive-queue", tab="pending", handover="Door to Door")
    assert door and all(e["handover_method"] == "Door to Door" for e in door)
    one, _ = _pages(client, t["csws"], "/donations/receive-queue", tab="pending", report_id=rids[1])
    assert one and {e["report_id"] for e in one} == {rids[1]}
    found, _ = _pages(client, t["csws"], "/donations/receive-queue", tab="pending", q=refs[10])
    assert [e["batch_reference"] for e in found] == [refs[10]]
    today, _ = _pages(client, t["csws"], "/donations/receive-queue", tab="pending", when="today")
    assert len(today) == 21

    s = ok(client.get("/donations/receive-queue/summary", headers=t["csws"]))
    assert s["pending"] == {"shown": 21, "total": 21}
    assert s["received"] == {"shown": 4, "total": 4}
    assert s["inventory"]["total"] == stotal
    assert {r["report_id"] for r in s["reports"]} == set(rids)
    assert s["barangays"]

    for who in ("donor", "cmo", "drrmo"):
        assert client.get("/donations/receive-queue", headers=t[who]).status_code == 403
    assert client.get("/donations/receive-queue", headers=t["csws"], params={"tab": "x"}).status_code == 422
