"""
Deliveries screen (Oct 9): sorting, filtering, readable names, and stock
messages; plus trips: several reports on one truck (api/v1/trips.py).

Example used throughout: 3 reports in Barangay Test (like Banilad) and one
in Barangay Two (a nearby barangay) leave together on one trip.
"""
from tests.test_inventory_paths import _add_item, _donate, _receive, _stock
from tests.test_role_flows import api, ok  # noqa: F401  (fixture)


def _report(client, t, barangay_id=1):
    rid = ok(client.post("/reports/", headers=t["unit"], json={
        "disaster_type_id": 1, "barangay_id": barangay_id, "estimated_quantity": 500}), 201)["report_id"]
    ok(client.post(f"/reports/{rid}/validate", headers=t["admin"], json={}))
    return rid


def _stocked(client, t, barangay_id=1, qty=100, item_id=1):
    rid = _report(client, t, barangay_id)
    _receive(client, t, _donate(client, t, rid, item_id, qty), qty)
    return rid


def _deliver(client, t, rid, items, date="2026-10-12T08:00:00+08:00", brgy=1):
    return client.post("/deliveries/", headers=t["csws"], json={
        "report_id": rid, "destination_barangay_id": brgy,
        "delivery_date": date, "items": items})


# ----------------------------------------------------------- delivery list
def test_delivery_list_filters_sorts_and_names(api):
    client, t = api
    water = _add_item("Water")
    a = _stocked(client, t)
    b = _stocked(client, t, barangay_id=2)
    _receive(client, t, _donate(client, t, b, water, 40), 40)

    d1 = ok(_deliver(client, t, a, [{"item_id": 1, "quantity": 10}], "2026-10-15T08:00:00+08:00"), 201)
    d2 = ok(_deliver(client, t, b, [{"item_id": water, "quantity": 5}], "2026-10-11T08:00:00+08:00", brgy=2), 201)
    d3 = ok(_deliver(client, t, a, [{"item_id": 1, "quantity": 1}], "2026-10-13T08:00:00+08:00"), 201)
    ok(client.post(f"/deliveries/{d2['delivery_id']}/advance", headers=t["csws"]))

    ids = lambda rows: [r["delivery_id"] for r in rows]
    get = lambda **p: ok(client.get("/deliveries/", headers=t["csws"], params=p))

    assert ids(get()) == [d3["delivery_id"], d2["delivery_id"], d1["delivery_id"]]   # newest first
    assert ids(get(sort="oldest")) == [d1["delivery_id"], d2["delivery_id"], d3["delivery_id"]]
    assert ids(get(sort="date_soonest")) == [d2["delivery_id"], d3["delivery_id"], d1["delivery_id"]]
    assert ids(get(sort="status"))[-1] == d2["delivery_id"]                          # In Transit after Preparing
    assert ids(get(status="In Transit")) == [d2["delivery_id"]]
    assert set(ids(get(status="Preparing,In Transit"))) == set(ids(get()))
    assert ids(get(date_from="2026-10-12", date_to="2026-10-14")) == [d3["delivery_id"]]
    assert ids(get(q="water")) == [d2["delivery_id"]]                                 # item name
    assert ids(get(q="Two")) == [d2["delivery_id"]]                                   # barangay name
    assert ids(get(q=f"#{d1['delivery_id']}")) == [d1["delivery_id"]]
    assert client.get("/deliveries/?sort=bogus", headers=t["csws"]).status_code == 422

    row = get(q="water")[0]
    assert row["destination_barangay_name"] == "Barangay Two" and row["report_label"].startswith(f"#{b} ")
    assert row["items"][0]["item_name"] == "Water"

    counts = ok(client.get("/deliveries/counts", headers=t["csws"]))
    assert counts == {"total": 3, "Preparing": 2, "In Transit": 1, "Delivered": 0, "Confirmed": 0}
    # Barangay reps only count their own barangay.
    assert ok(client.get("/deliveries/counts", headers=t["brgy2"]))["total"] == 1


def test_stock_messages_name_the_item(api):
    client, t = api
    rid = _stocked(client, t, qty=50)
    r = _deliver(client, t, rid, [{"item_id": 1, "quantity": 60}])
    assert r.status_code == 409 and "only 50 kg of Rice left" in r.json()["detail"]
    ok(_deliver(client, t, rid, [{"item_id": 1, "quantity": 50}]), 201)
    r = _deliver(client, t, rid, [{"item_id": 1, "quantity": 1}])
    assert r.status_code == 409 and r.json()["detail"] == "No more stock of Rice for this report."


# ------------------------------------------------------------------ trips
def _trip(client, t, reports, **extra):
    return client.post("/trips/", headers=t["csws"], json={
        "trip_date": "2026-10-12T07:00:00+08:00", "vehicle_details": "City truck ABC 1234",
        "reports": reports, **extra})


def test_candidates_put_the_chosen_barangay_first_and_flag_empty_reports(api):
    client, t = api
    a = _stocked(client, t)
    b = _stocked(client, t, barangay_id=2)
    empty = _report(client, t)
    c = ok(client.get("/trips/candidates", headers=t["csws"], params={"near_barangay_id": 2}))
    assert [g["barangay_id"] for g in c["barangays"]] == [2, 1]
    assert [r["report_id"] for r in c["barangays"][1]["reports"]] == [a]
    assert c["barangays"][0]["reports"][0]["items"][0] == {
        "item_id": 1, "item_name": "Rice", "unit": "kg", "quantity": 100}
    assert c["no_stock_reports"] == [{"report_id": empty, "report_label": c["no_stock_reports"][0]["report_label"],
                                      "barangay_name": "Barangay Test",
                                      "message": "No more stock for this report"}]
    assert b in [r["report_id"] for r in c["barangays"][0]["reports"]]
    assert client.get("/trips/candidates", headers=t["donor"]).status_code == 403


def test_one_trip_for_several_reports_end_to_end(api):
    client, t = api
    banilad = [_stocked(client, t) for _ in range(3)]
    nearby = _stocked(client, t, barangay_id=2)
    trip = ok(_trip(client, t, [
        {"report_id": banilad[0], "items": [{"item_id": 1, "quantity": 30}]},
        {"report_id": nearby, "items": [{"item_id": 1, "quantity": 20}]},
        {"report_id": banilad[1], "items": [{"item_id": 1, "quantity": 10}, {"item_id": 1, "quantity": 5}]},
        {"report_id": banilad[2], "items": [{"item_id": 1, "quantity": 100}]},
    ]), 201)
    tid = trip["trip_id"]
    assert trip["status"] == "Preparing" and trip["status_label"] == "Being prepared"
    assert (trip["total_reports"], trip["total_stops"], trip["total_quantity"]) == (4, 2, 165)
    # Stops follow the order staff listed the barangays; same barangay = same stop.
    assert [(s["stop_order"], s["barangay_id"], len(s["deliveries"])) for s in trip["stops"]] == [(1, 1, 3), (2, 2, 1)]
    assert [_stock(1, r) for r in banilad] == [70, 85, 0] and _stock(1, nearby) == 80

    # Each delivery is an ordinary delivery: listed, filterable by trip.
    rows = ok(client.get("/deliveries/", headers=t["csws"], params={"trip_id": tid}))
    assert len(rows) == 4 and all(r["trip_id"] == tid for r in rows)

    # Start: everything goes In Transit with the usual history.
    started = ok(client.post(f"/trips/{tid}/start", headers=t["csws"]))
    assert started["status"] == "In Transit" and started["delivery_counts"]["In Transit"] == 4
    hist = ok(client.get(f"/deliveries/{rows[0]['delivery_id']}/history", headers=t["csws"]))
    assert [h["action"] for h in hist["history"]] == ["PREPARE DELIVERY", "UPDATE DELIVERY STATUS"]
    assert client.post(f"/trips/{tid}/start", headers=t["csws"]).status_code == 409

    # Stop 1 (Barangay Test): 3 deliveries arrive with one tap.
    after1 = ok(client.post(f"/trips/{tid}/stops/1/arrived", headers=t["csws"]))
    assert after1["stops"][0]["status"] == "Delivered" and after1["stops"][1]["status"] == "In Transit"
    assert client.post(f"/trips/{tid}/stops/1/arrived", headers=t["csws"]).status_code == 409

    # The Barangay Test rep confirms all three at once; the other stop is not theirs.
    assert client.post(f"/trips/{tid}/confirm-receipt", headers=t["brgy2"], json={}).status_code == 409
    done = ok(client.post(f"/trips/{tid}/confirm-receipt", headers=t["brgy"], json={"remarks": "complete"}))
    assert len(done["confirmed_deliveries"]) == 3
    from tests.test_inventory_paths import database
    from models.report import ReportFulfillment
    db = database.SessionLocal()
    try:   # fulfillment is recalculated per report
        delivered = {f.report_id: f.total_items_delivered for f in db.query(ReportFulfillment)}
    finally:
        db.close()
    assert [delivered[r] for r in banilad] == [30, 15, 100] and delivered[nearby] == 0

    # Stop 2, then that rep confirms: the trip completes by itself.
    ok(client.post(f"/trips/{tid}/stops/2/arrived", headers=t["csws"]))
    assert ok(client.get(f"/trips/{tid}", headers=t["csws"]))["status"] == "Delivered"
    ok(client.post(f"/trips/{tid}/confirm-receipt", headers=t["brgy2"], json={}))
    final = ok(client.get(f"/trips/{tid}", headers=t["drrmo"]))
    assert final["status"] == "Completed" and final["delivery_counts"]["Confirmed"] == 4

    listed = ok(client.get("/trips/", headers=t["csws"], params={"status": "Completed"}))
    assert [x["trip_id"] for x in listed] == [tid]
    assert ok(client.get("/trips/", headers=t["csws"], params={"q": "Two"}))[0]["trip_id"] == tid
    assert ok(client.get("/trips/", headers=t["csws"], params={"status": "Preparing"})) == []


def test_trip_stock_is_all_or_nothing(api):
    client, t = api
    a = _stocked(client, t, qty=50)
    b = _stocked(client, t, barangay_id=2, qty=10)
    r = _trip(client, t, [
        {"report_id": a, "items": [{"item_id": 1, "quantity": 40}]},
        {"report_id": b, "items": [{"item_id": 1, "quantity": 11}]},
    ])
    assert r.status_code == 409 and "only 10 kg of Rice left for report #" in r.json()["detail"]
    assert _stock(1, a) == 50 and _stock(1, b) == 10                 # nothing taken
    assert ok(client.get("/trips/", headers=t["csws"])) == []

    dup = _trip(client, t, [{"report_id": a, "items": [{"item_id": 1, "quantity": 1}]},
                            {"report_id": a, "items": [{"item_id": 1, "quantity": 1}]}])
    assert dup.status_code == 400 and "listed twice" in dup.json()["detail"]
    unvalidated = ok(client.post("/reports/", headers=t["unit"], json={
        "disaster_type_id": 1, "barangay_id": 1, "estimated_quantity": 5}), 201)["report_id"]
    assert _trip(client, t, [{"report_id": unvalidated, "items": [{"item_id": 1, "quantity": 1}]}]).status_code == 409
    assert client.post("/trips/", headers=t["donor"], json={}).status_code == 403


def test_undo_trip_returns_stock_only_before_it_leaves(api):
    client, t = api
    a = _stocked(client, t)
    b = _stocked(client, t, barangay_id=2)
    body = [{"report_id": a, "items": [{"item_id": 1, "quantity": 30}]},
            {"report_id": b, "items": [{"item_id": 1, "quantity": 20}]}]
    tid = ok(_trip(client, t, body), 201)["trip_id"]
    out = ok(client.delete(f"/trips/{tid}", headers=t["csws"]))
    assert out["undone"] and _stock(1, a) == 100 and _stock(1, b) == 100
    assert client.get(f"/trips/{tid}", headers=t["csws"]).status_code == 404
    assert ok(client.get("/deliveries/", headers=t["csws"])) == []

    tid = ok(_trip(client, t, body), 201)["trip_id"]
    ok(client.post(f"/trips/{tid}/start", headers=t["csws"]))
    assert client.delete(f"/trips/{tid}", headers=t["csws"]).status_code == 409
    assert _stock(1, a) == 70


def test_single_deliveries_still_work_without_a_trip(api):
    client, t = api
    rid = _stocked(client, t)
    d = ok(_deliver(client, t, rid, [{"item_id": 1, "quantity": 5}]), 201)
    assert d["trip_id"] is None
    ok(client.post(f"/deliveries/{d['delivery_id']}/advance", headers=t["csws"]))
    ok(client.post(f"/deliveries/{d['delivery_id']}/advance", headers=t["csws"]))
    ok(client.post(f"/deliveries/{d['delivery_id']}/confirm-receipt", headers=t["brgy"], json={}), 201)
