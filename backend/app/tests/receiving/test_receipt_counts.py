"""J1 / NF-009 (team agreement Nov 18, 2026): the Barangay Receiving
Representative counts every item at receipt (UC-B1).

Done when (task brief J1):
  - no line, or a missing line                     -> 422
  - a count that differs, without a reason         -> 422
  - a short count lowers the fulfillment % and the priority is recalculated
Also covered: the reason must fit ("Over" only when more arrived; Short,
Damaged or Wrong item only when fewer; none when equal); a difference is
still Confirmed with has_discrepancy = true and tells CSWS Main Office and
the reporter; delivered = min(received, sent), so an over-count never
raises fulfillment; receipts saved before counting keep the sent quantity;
the database refuses a difference without a reason; a trip takes counts per
delivery, all or nothing.

J2 / NF-015: every confirm also carries the handover code and a signature
(tests/receipt_helpers.py proof), so these tests reach the J1 checks.
"""
import pytest
from sqlalchemy.exc import IntegrityError

import core.config.database as database
from models.deliveries.delivery import Delivery, Receipt, ReceiptItem
from models.reports.report import DisasterReport
from models.accounts.user_rbac_model import User
from services.deliveries.fulfillment import progress
from tests.receipt_helpers import ANY_TRIP_COUNTS, full_counts, proof, trip_counts
from tests.deliveries.test_delivery_trips import _deliver, _stocked, _trip
from tests.receiving.test_inventory_paths import _add_item, _donate, _receive
from tests.pickup.test_pickup_days_and_runs import _activate_everyone
from tests.general.test_role_flows import ACCOUNTS, api, ok  # noqa: F401  (fixture)


# ------------------------------------------------------------------ helpers
def _arrived(client, t, rid, items):
    """A delivery that reached Barangay Test (status Delivered)."""
    did = ok(_deliver(client, t, rid, items), 201)["delivery_id"]
    ok(client.post(f"/deliveries/{did}/advance", headers=t["csws"]))   # In Transit
    ok(client.post(f"/deliveries/{did}/advance", headers=t["csws"]))   # Delivered
    return did


def _line_ids(client, t, did) -> dict:
    """{item_id: delivery_item_id} of a delivery."""
    d = ok(client.get(f"/deliveries/{did}", headers=t["csws"]))
    return {i["item_id"]: i["delivery_item_id"] for i in d["items"]}


def _count(line, received, reason=None, note=None) -> dict:
    c = {"delivery_item_id": line, "received_quantity": received}
    if reason is not None:
        c["discrepancy_reason"] = reason
    if note is not None:
        c["discrepancy_note"] = note
    return c


def _confirm(client, t, did, counts, who="brgy"):
    body = {"items": counts, **proof(client, did, t[who])}
    return client.post(f"/deliveries/{did}/confirm-receipt", headers=t[who], json=body)


def _status(client, t, did):
    return ok(client.get(f"/deliveries/{did}", headers=t["csws"]))["status"]


def _rep_id():
    db = database.SessionLocal()
    try:
        return db.query(User).filter(User.email == ACCOUNTS["brgy"][0]).one().user_id
    finally:
        db.close()


def _report_of_100(client, t):
    """A validated report for 60 families needing 100 kg of rice, all in stock."""
    rid = ok(client.post("/reports/", headers=t["unit"], json={
        "disaster_type_id": 1, "barangay_id": 1, "affected_families": 60,
        "estimated_quantity": 100}), 201)["report_id"]
    ok(client.post(f"/reports/{rid}/validate", headers=t["admin"], json={}))
    _receive(client, t, _donate(client, t, rid, 1, 100), 100)
    return rid


# ------------------------------------------------- Done when: the 422 cases
def test_no_line_or_a_missing_line_is_refused(api):
    client, t = api
    water = _add_item("Water")
    rid = _stocked(client, t)
    _receive(client, t, _donate(client, t, rid, water, 20), 20)
    did = _arrived(client, t, rid, [{"item_id": 1, "quantity": 30}, {"item_id": water, "quantity": 12}])
    lines = _line_ids(client, t, did)
    url = f"/deliveries/{did}/confirm-receipt"
    both = [_count(lines[1], 30), _count(lines[water], 12)]

    # No count at all: an empty body, remarks only, an empty list.
    for body in ({}, {"remarks": "All here"}, {"items": []}):
        assert client.post(url, headers=t["brgy"], json=body).status_code == 422, body
    # The count field starts empty: a line without a number is refused.
    assert _confirm(client, t, did, [{"delivery_item_id": lines[1]}, both[1]]).status_code == 422
    # One of the two lines missing.
    r = _confirm(client, t, did, both[:1])
    assert r.status_code == 422 and "Missing: Water" in r.json()["detail"]
    # A line counted twice, a line of another delivery, a negative count.
    assert _confirm(client, t, did, both + both[:1]).status_code == 422
    assert _confirm(client, t, did, both + [_count(9999, 1)]).status_code == 422
    assert _confirm(client, t, did, [_count(lines[1], -1, "Short"), both[1]]).status_code == 422

    # Nothing was saved, and a full count then goes through.
    assert _status(client, t, did) == "Delivered"
    body = ok(_confirm(client, t, did, both), 201)
    assert body["delivery"]["status"] == "Confirmed"
    assert body["receipt"]["has_discrepancy"] is False and body["delivery"]["has_discrepancy"] is False
    assert sorted((i["expected_quantity"], i["received_quantity"])
                  for i in body["receipt"]["items"]) == [(12, 12), (30, 30)]


def test_a_difference_needs_a_reason_that_fits(api):
    client, t = api
    did = _arrived(client, t, _stocked(client, t), [{"item_id": 1, "quantity": 50}])
    line = _line_ids(client, t, did)[1]

    r = _confirm(client, t, did, [_count(line, 40)])                              # fewer, no reason
    assert r.status_code == 422 and "Short, Damaged or Wrong item" in r.json()["detail"]
    r = _confirm(client, t, did, [_count(line, 60)])                              # more, no reason
    assert r.status_code == 422 and '"Over"' in r.json()["detail"]
    assert _confirm(client, t, did, [_count(line, 40, "Over")]).status_code == 422     # fewer: not Over
    assert _confirm(client, t, did, [_count(line, 60, "Short")]).status_code == 422    # more: only Over
    assert _confirm(client, t, did, [_count(line, 50, "Short")]).status_code == 422    # equal: no reason
    assert _confirm(client, t, did, [_count(line, 50, note="ok")]).status_code == 422  # equal: no note
    assert _confirm(client, t, did, [_count(line, 40, "Lost")]).status_code == 422     # not a reason
    assert _status(client, t, did) == "Delivered"                                      # nothing saved

    body = ok(_confirm(client, t, did, [_count(line, 40, "Damaged", "10 kg soaked by rain")]), 201)
    item = body["receipt"]["items"][0]
    assert (item["expected_quantity"], item["received_quantity"], item["discrepancy_reason"],
            item["discrepancy_note"]) == (50, 40, "Damaged", "10 kg soaked by rain")


# ---------------------------- Done when: a short count lowers fulfillment
def test_a_short_count_lowers_fulfillment_and_the_priority_follows(api):
    client, t = api
    full, short = _report_of_100(client, t), _report_of_100(client, t)
    d_full = _arrived(client, t, full, [{"item_id": 1, "quantity": 100}])
    d_short = _arrived(client, t, short, [{"item_id": 1, "quantity": 100}])

    # Counted as sent: 100 of 100 delivered.
    body = ok(client.post(f"/deliveries/{d_full}/confirm-receipt", headers=t["brgy"],
                          json=full_counts(client, d_full, t["brgy"])), 201)
    assert float(body["fulfillment"]["fulfillment_percentage"]) == 100.0

    # The same 100 kg sent, but only 50 kg counted.
    line = _line_ids(client, t, d_short)[1]
    body = ok(_confirm(client, t, d_short, [_count(line, 50, "Short", "Half the rice was missing")]), 201)
    assert body["delivery"]["status"] == "Confirmed"                               # still Confirmed
    assert body["delivery"]["has_discrepancy"] is True and body["receipt"]["has_discrepancy"] is True
    f = body["fulfillment"]
    assert f["total_items_delivered"] == 50                                        # counted, not sent
    assert float(f["fulfillment_percentage"]) == 50.0 and f["verification_status"] == "Partial"

    # The priority is recalculated from the counted quantity.
    a = ok(client.get(f"/reports/{full}", headers=t["admin"]))
    b = ok(client.get(f"/reports/{short}", headers=t["admin"]))
    assert a["priority_level"] == "Low"
    assert b["priority_level"] in ("High", "Medium")
    assert float(b["ai_priority_score"]) > float(a["ai_priority_score"])


def test_an_over_count_never_raises_fulfillment(api):
    client, t = api
    rid = _stocked(client, t)                                                      # needs 500 kg
    did = _arrived(client, t, rid, [{"item_id": 1, "quantity": 30}])
    body = ok(_confirm(client, t, did, [_count(_line_ids(client, t, did)[1], 40, "Over")]), 201)
    assert body["receipt"]["items"][0]["received_quantity"] == 40                  # the count is kept
    assert body["delivery"]["has_discrepancy"] is True
    assert body["fulfillment"]["total_items_delivered"] == 30                      # min(40, 30)
    assert float(body["fulfillment"]["fulfillment_percentage"]) == 6.0


# ------------------------------------------------- notices and the screens
def test_a_difference_tells_main_office_and_the_reporter(api):
    client, t = api
    _activate_everyone()
    did = _arrived(client, t, _stocked(client, t), [{"item_id": 1, "quantity": 50}])
    ok(_confirm(client, t, did, [_count(_line_ids(client, t, did)[1], 45, "Short")]), 201)

    for who in ("csws", "unit"):                     # CSWS Main Office and the reporter
        notes = ok(client.get("/notifications/", headers=t[who]))["items"]
        hits = [n for n in notes if n["type"] == "delivery_receipt_discrepancy"]
        assert len(hits) == 1 and "Rice: 45 of 50 kg (Short)" in hits[0]["message"], who
        assert "delivery_receipt_confirmed" not in [n["type"] for n in notes], who   # one notice each
    mine = [n["type"] for n in ok(client.get("/notifications/", headers=t["brgy"]))["items"]]
    assert "delivery_receipt_discrepancy" not in mine          # the rep is not told about their own count


def test_the_delivery_screens_show_what_the_barangay_counted(api):
    client, t = api
    did = _arrived(client, t, _stocked(client, t), [{"item_id": 1, "quantity": 50}])
    row = ok(client.get(f"/deliveries/{did}", headers=t["brgy"]))
    assert row["items"][0]["received_quantity"] is None and row["has_discrepancy"] is False

    ok(_confirm(client, t, did, [_count(row["items"][0]["delivery_item_id"], 48, "Short")]), 201)
    one = ok(client.get(f"/deliveries/{did}", headers=t["brgy"]))
    listed = ok(client.get("/deliveries/", headers=t["csws"], params={"status": "Confirmed"}))[0]
    for view in (one, listed):                       # one delivery, and the list (delivery_views)
        assert view["has_discrepancy"] is True
        line = view["items"][0]
        assert (line["quantity"], line["received_quantity"], line["discrepancy_reason"]) == (50, 48, "Short")


# ------------------------------------------------------ old receipts, the DB
def test_receipts_from_before_counting_keep_the_sent_quantity(api):
    client, t = api
    rep = _rep_id()
    rid = _stocked(client, t)
    did = _arrived(client, t, rid, [{"item_id": 1, "quantity": 30}])
    db = database.SessionLocal()
    try:   # confirmed the old way (before Nov 2026): a receipt with no counts
        db.add(Receipt(delivery_id=did, received_by_user_id=rep, remarks="One tap"))
        db.get(Delivery, did).status = "Confirmed"
        db.commit()
        assert db.query(ReceiptItem).count() == 0
        assert progress(db, db.get(DisasterReport, rid))["needs"][0]["delivered"] == 30
    finally:
        db.close()
    row = ok(client.get(f"/deliveries/{did}", headers=t["csws"]))
    assert row["status"] == "Confirmed" and row["has_discrepancy"] is False
    assert row["items"][0]["received_quantity"] is None


def test_the_database_refuses_a_difference_without_a_reason(api):
    client, t = api
    rep = _rep_id()
    did = _arrived(client, t, _stocked(client, t), [{"item_id": 1, "quantity": 30}])
    db = database.SessionLocal()
    try:
        line = db.get(Delivery, did).items[0]
        receipt = Receipt(delivery_id=did, received_by_user_id=rep)
        receipt.items.append(ReceiptItem(delivery_item_id=line.delivery_item_id,
                                         expected_quantity=30, received_quantity=20))
        db.add(receipt)
        with pytest.raises(IntegrityError):          # chk_receipt_items_reason_fits
            db.commit()
        db.rollback()
    finally:
        db.close()


# ------------------------------------------------------------------- trips
def test_a_trip_takes_counts_for_each_delivery_all_or_nothing(api):
    client, t = api
    a, b = _stocked(client, t), _stocked(client, t)
    tid = ok(_trip(client, t, [
        {"report_id": a, "items": [{"item_id": 1, "quantity": 30}]},
        {"report_id": b, "items": [{"item_id": 1, "quantity": 20}]},
    ]), 201)["trip_id"]
    ok(client.post(f"/trips/{tid}/start", headers=t["csws"]))
    ok(client.post(f"/trips/{tid}/stops/1/arrived", headers=t["csws"]))
    url = f"/trips/{tid}/confirm-receipt"

    # Remarks only, or no deliveries: refused.
    for bad in ({}, {"remarks": "complete"}, {"deliveries": []}):
        assert client.post(url, headers=t["brgy"], json=bad).status_code == 422, bad
    assert client.post(url, headers=t["brgy2"], json=ANY_TRIP_COUNTS).status_code == 403   # not their stop (J4)

    body = trip_counts(client, tid, t["brgy"])      # counts, the stop's code and a signature
    first, second = body["deliveries"]
    # A delivery left out, or one that is not on this stop: refused.
    r = client.post(url, headers=t["brgy"], json={**body, "deliveries": [first]})
    assert r.status_code == 422 and "Missing: delivery" in r.json()["detail"]
    extra = {"delivery_id": 9999, "items": first["items"]}
    assert client.post(url, headers=t["brgy"],
                       json={**body, "deliveries": [first, second, extra]}).status_code == 422
    # One short line without a reason: nothing at all is confirmed.
    short = {**second["items"][0], "received_quantity": second["items"][0]["received_quantity"] - 5}
    bad = {**body, "deliveries": [first, {**second, "items": [short]}]}
    assert client.post(url, headers=t["brgy"], json=bad).status_code == 422
    rows = ok(client.get("/deliveries/", headers=t["brgy"], params={"trip_id": tid}))
    assert {row["status"] for row in rows} == {"Delivered"}

    # With a reason, both are confirmed together, each with its own counts.
    fixed = {**short, "discrepancy_reason": "Wrong item"}
    done = ok(client.post(url, headers=t["brgy"], json={
        **body, "deliveries": [first, {**second, "items": [fixed]}], "remarks": "Stop 1"}))
    assert sorted(done["confirmed_deliveries"]) == sorted([first["delivery_id"], second["delivery_id"]])
    assert done["with_differences"] == [second["delivery_id"]]
    db = database.SessionLocal()
    try:
        counted = {r.delivery_id: [(i.expected_quantity, i.received_quantity, i.discrepancy_reason)
                                   for i in r.items] for r in db.query(Receipt).all()}
    finally:
        db.close()
    sent_first = first["items"][0]["received_quantity"]
    sent_second = second["items"][0]["received_quantity"]
    assert counted == {
        first["delivery_id"]: [(sent_first, sent_first, None)],
        second["delivery_id"]: [(sent_second, sent_second - 5, "Wrong item")],
    }
