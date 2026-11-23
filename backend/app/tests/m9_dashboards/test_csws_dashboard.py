"""Nov 23, 2026: the CSWS Main Office dashboard (four cards, inventory,
recent activity) and its pages (core/m9_dashboards/csws_overview_routes.py)."""
from datetime import datetime, timedelta, timezone

import core.shared.database as database
from core.m4_donation_management.physical_donation_model import PhysicalDonation
from tests.m1_user_management.test_role_flows import api, ok  # noqa: F401  (fixture)


def _report(client, t, qty=100, barangay_id=1, disaster_type_id=1):
    rid = ok(client.post("/reports/", headers=t["unit"], json={
        "disaster_type_id": disaster_type_id, "barangay_id": barangay_id,
        "estimated_quantity": qty}), 201)["report_id"]
    ok(client.post(f"/reports/{rid}/validate", headers=t["admin"], json={}))
    return rid


def _donate(client, t, rid, qty):
    return ok(client.post("/donations/", headers=t["donor"], json={
        "report_id": rid, "item_id": 1, "packaging": "Sack", "quantity": qty,
        "handover_method": "Drop Off"}))


def _stock(client, t, rid, qty):
    d = _donate(client, t, rid, qty)
    ok(client.post("/donations/receive", headers=t["csws"],
                   json={"donation_id": d["donation_id"], "actual_quantity": qty}))
    return d


def _page(client, t, path, **query):
    r = client.get(path, headers=t["csws"], params={"limit": 10, "offset": 0, **query})
    assert r.status_code == 200, r.text
    return r.json(), int(r.headers["X-Total-Count"])


def _due_today(donation_id):
    db = database.SessionLocal()
    try:
        db.get(PhysicalDonation, donation_id).expires_at = (
            datetime.now(timezone.utc) + timedelta(hours=1))
        db.commit()
    finally:
        db.close()


def test_overview_four_cards_inventory_and_activity(api):
    client, t = api
    rid = _report(client, t)
    _stock(client, t, rid, 60)
    ok(client.post("/deliveries/", headers=t["csws"], json={
        "report_id": rid, "destination_barangay_id": 1, "delivery_date": "2099-01-01T08:00:00",
        "items": [{"item_id": 1, "quantity": 10}]}), 201)
    _due_today(_donate(client, t, rid, 7)["donation_id"])
    _donate(client, t, rid, 3)

    m = ok(client.get("/dashboard/csws-main", headers=t["csws"]))
    assert (m["waiting"], m["due_today"]) == (2, 1)
    assert m["expired_donations"] == 0 and m["cancelled_donations"] == 0
    assert m["entries_received"] == 1 and m["deliveries_made"] == 1
    assert [(r["item_name"], r["quantity"]) for r in m["inventory"]["rows"]] == [("Rice", 50)]
    assert m["inventory"]["reports_with_stock"] == 1
    assert len(m["recent_activity"]) <= 10 and m["recent_activity"]
    for gone in ("most_urgent", "alerts", "needs_attention", "operations", "per_report"):
        assert gone not in m

    # Waiting to be received: every pledge, "due" = due today or late
    _, total = _page(client, t, "/dashboard/csws-main/waiting")
    assert total == 2
    rows, total = _page(client, t, "/dashboard/csws-main/waiting", filter="due")
    assert total == 1 and rows[0]["due_today"] is True
    assert ok(client.get("/dashboard/csws-main/waiting/counts", headers=t["csws"])) == {
        "all": 2, "due": 1, "Drop Off": 2, "Door to Door": 0}
    assert client.get("/dashboard/csws-main/waiting", headers=t["donor"]).status_code == 403
    # The removed pages are gone
    for gone in ("urgent", "alerts", "transport", "overdue", "issues", "operations"):
        assert client.get(f"/dashboard/csws-main/{gone}", headers=t["csws"]).status_code == 404


def test_inventory_is_what_was_received_per_report(api):
    client, t = api
    a, b = _report(client, t), _report(client, t)
    _stock(client, t, a, 60)
    _stock(client, t, b, 15)
    _donate(client, t, a, 99)                 # pledged only: never in the inventory

    rows, total = _page(client, t, "/inventory/summary")
    assert total == 1 and rows[0]["quantity"] == 75 and rows[0]["category_group"] == "food_water"

    cards, total = _page(client, t, "/inventory/per-report")
    assert total == 2 and [c["report_id"] for c in cards] == [a, b]     # most stock first
    assert cards[0]["stock_units"] == 60 and cards[0]["top_items"][0]["item_name"] == "Rice"
    assert "items" not in cards[0]
    for gone in ("fulfillment_percentage", "lacking_count", "top_lacking", "pledged_share"):
        assert gone not in cards[0]

    items, total = _page(client, t, f"/inventory/per-report/{a}")
    assert total == 1 and items[0]["quantity"] == 60
    assert ok(client.get(f"/inventory/per-report/{a}/counts", headers=t["csws"]))["food_water"] == 1
    assert client.get("/inventory/per-report/999999", headers=t["csws"]).status_code == 404


def test_inventory_filters_by_barangay_and_disaster_type(api):
    """Nov 24: the inventory has the Barangay and Disaster type filters of
    every report list (stock is held per report)."""
    client, t = api
    a = _report(client, t, barangay_id=1, disaster_type_id=1)
    b = _report(client, t, barangay_id=2, disaster_type_id=2)
    _stock(client, t, a, 60)
    _stock(client, t, b, 15)

    rows, _ = _page(client, t, "/inventory/summary", barangay_id=2)
    assert [r["quantity"] for r in rows] == [15]
    rows, _ = _page(client, t, "/inventory/summary", disaster_type_id=1)
    assert [r["quantity"] for r in rows] == [60]
    rows, total = _page(client, t, "/inventory/summary", barangay_id=1, disaster_type_id=2)
    assert total == 0
    counts = ok(client.get("/inventory/summary/counts", headers=t["csws"],
                           params={"barangay_id": 2}))
    assert counts["all"] == 1 and counts["food_water"] == 1

    cards, total = _page(client, t, "/inventory/per-report", barangay_id=2)
    assert total == 1 and cards[0]["report_id"] == b
    cards, total = _page(client, t, "/inventory/per-report", disaster_type_id=1)
    assert total == 1 and cards[0]["report_id"] == a
    assert ok(client.get("/inventory/per-report/counts", headers=t["csws"],
                         params={"disaster_type_id": 2})) == {"all": 1}


def test_overview_cache_shares_one_answer_without_hanging(api):
    """With the cache on (as in production): building a cached value may
    read another cached value from the same thread without deadlocking,
    callers that arrive together get one build, and the overview works."""
    import threading

    from core.m9_dashboards import csws_overview
    client, t = api
    csws_overview.CACHE["on"] = True
    try:
        builds = []

        def build():
            builds.append(1)
            return csws_overview.cached("inner", 10, lambda: 42)

        answers = []
        threads = [threading.Thread(
            target=lambda: answers.append(csws_overview.cached("outer", 10, build)),
            daemon=True) for _ in range(3)]
        for th in threads:
            th.start()
        for th in threads:
            th.join(10)
        assert answers == [42, 42, 42] and len(builds) == 1
        assert client.get("/dashboard/csws-main", headers=t["csws"]).status_code == 200
    finally:
        csws_overview.CACHE["on"] = False
        csws_overview.clear_cache()
