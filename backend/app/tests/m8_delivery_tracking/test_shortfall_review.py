"""J5 / NF-010 (team agreement Nov 18, 2026, A3): CSWS shortfall review.

Done when (task brief J5):
  - a short delivery is listed (GET /deliveries/discrepancies)
  - a review without a cause = 422
  - stock is unchanged by a review
Also: an exact or over-count delivery is not listed; an invalid cause =
422; only CSWS Main Office reviews (the Administrator only reads); a new
review replaces the cause and the audit log keeps both; a delivery not
Confirmed or without a short line = 409; the reviewed filter and paging.
"""
import core.shared.database as database
from core.shared.audit_log_model import AuditLog
from core.m5_inventory.inventory_model import Inventory
from core.m8_delivery_tracking.shortfall import REVIEW_ACTION
from tests.receipt_helpers import proof
from tests.m8_delivery_tracking.test_delivery_trips import _deliver, _stocked
from tests.m1_user_management.test_role_flows import api, ok  # noqa: F401  (fixture)

URL = "/deliveries/discrepancies"


# ------------------------------------------------------------------ helpers
def _arrived(client, t, sent=50):
    """A delivery of [sent] kg rice to Barangay Test, now Delivered."""
    rid = _stocked(client, t)
    did = ok(_deliver(client, t, rid, [{"item_id": 1, "quantity": sent}]), 201)["delivery_id"]
    ok(client.post(f"/deliveries/{did}/advance", headers=t["csws"]))   # In Transit
    ok(client.post(f"/deliveries/{did}/advance", headers=t["csws"]))   # Delivered
    return did, rid


def _confirmed(client, t, sent=50, received=40, reason=None, note=None):
    """A delivery the rep confirmed, counting [received] of [sent]."""
    did, rid = _arrived(client, t, sent)
    line = ok(client.get(f"/deliveries/{did}", headers=t["brgy"]))["items"][0]["delivery_item_id"]
    count = {"delivery_item_id": line, "received_quantity": received}
    if received != sent:
        count["discrepancy_reason"] = reason or ("Short" if received < sent else "Over")
        if note:
            count["discrepancy_note"] = note
    ok(client.post(f"/deliveries/{did}/confirm-receipt", headers=t["brgy"],
                   json={"items": [count], **proof(client, did, t["brgy"])}), 201)
    return did, rid


def _review(client, t, did, body, who="csws"):
    return client.post(f"/deliveries/{did}/discrepancy-review", headers=t[who], json=body)


def _ids(rows):
    return [r["delivery_id"] for r in rows]


# ------------------------------------------------ Done when: short is listed
def test_a_short_delivery_is_listed_and_exact_or_over_counts_are_not(api):
    client, t = api
    short, rid = _confirmed(client, t, 50, 40, "Damaged", "Two sacks soaked")
    _confirmed(client, t, 30, 30)                       # counted as sent
    _confirmed(client, t, 20, 25)                       # more than sent
    _arrived(client, t)                                 # not confirmed yet

    r = client.get(URL, headers=t["csws"])
    assert r.status_code == 200 and r.headers["X-Total-Count"] == "1"
    rows = r.json()
    assert _ids(rows) == [short]
    row = rows[0]
    assert (row["barangay_name"], row["report_id"]) == ("Barangay Test", rid)
    assert row["received_at"] and row["report_label"]
    line = row["short_lines"][0]
    assert (line["item_name"], line["unit"], line["expected_quantity"], line["received_quantity"],
            line["discrepancy_reason"], line["discrepancy_note"]) == (
        "Rice", "kg", 50, 40, "Damaged", "Two sacks soaked")
    assert (row["cause"], row["note"], row["reviewed_at"], row["reviewed_by"]) == (None, None, None, None)
    # The Administrator reads the same list.
    assert _ids(ok(client.get(URL, headers=t["admin"]))) == [short]


# ------------------------------------- Done when: review without cause = 422
def test_a_review_needs_a_valid_cause(api):
    client, t = api
    did, _ = _confirmed(client, t)
    for body in ({}, {"note": "Checked with the driver"}, {"cause": None},
                 {"cause": "Stolen"}, {"cause": "damaged"}, {"cause": ""},
                 {"cause": "Damaged", "note": "x" * 501}):
        assert _review(client, t, did, body).status_code == 422, body
    assert ok(client.get(URL, headers=t["csws"]))[0]["cause"] is None       # nothing saved
    for cause in ("Damaged", "Lost in transit", "Miscount at office", "Miscount at barangay"):
        assert ok(_review(client, t, did, {"cause": cause}))["cause"] == cause


# --------------------------------------------- Done when: stock is unchanged
def _stock_rows():
    db = database.SessionLocal()
    try:
        return sorted((i.item_id, i.report_id, i.quantity) for i in db.query(Inventory))
    finally:
        db.close()


def test_a_review_never_changes_stock_fulfillment_or_priority(api):
    client, t = api
    did, rid = _confirmed(client, t, 50, 40)
    stock = _stock_rows()
    report = ok(client.get(f"/reports/{rid}", headers=t["admin"]))

    ok(_review(client, t, did, {"cause": "Miscount at office", "note": "Recount at the office"}))
    ok(_review(client, t, did, {"cause": "Lost in transit"}))

    assert _stock_rows() == stock                         # no automatic stock restore
    after = ok(client.get(f"/reports/{rid}", headers=t["admin"]))
    for key in ("fulfillment_percentage", "fulfillment_status", "priority_level", "ai_priority_score"):
        assert after[key] == report[key], key


# --------------------------------------------------------------- who may
def test_only_csws_main_office_reviews_and_the_administrator_only_reads(api):
    client, t = api
    did, _ = _confirmed(client, t)
    body = {"cause": "Damaged"}
    for who in ("brgy", "drrmo", "unit", "admin", "donor", "cmo"):
        assert _review(client, t, did, body, who=who).status_code == 403, who
    for who in ("brgy", "unit", "drrmo", "donor", "cmo"):
        assert client.get(URL, headers=t[who]).status_code == 403, who
    assert ok(client.get(URL, headers=t["admin"]))[0]["cause"] is None     # nothing saved
    ok(_review(client, t, did, body))                                       # CSWS Main Office


# ------------------------------------------- re-review keeps the history
def test_a_new_review_replaces_the_cause_and_the_audit_log_keeps_both(api):
    client, t = api
    did, _ = _confirmed(client, t)
    first = ok(_review(client, t, did, {"cause": "Damaged", "note": "  Wet sacks  "}))
    assert (first["cause"], first["note"], first["reviewed_by"]) == ("Damaged", "Wet sacks", "csws Test")
    assert first["reviewed_at"]
    second = ok(_review(client, t, did, {"cause": "Lost in transit", "note": "   "}))
    assert (second["cause"], second["note"]) == ("Lost in transit", None)
    assert ok(client.get(URL, headers=t["csws"]))[0]["cause"] == "Lost in transit"

    db = database.SessionLocal()
    try:
        logs = (db.query(AuditLog)
                .filter(AuditLog.action == REVIEW_ACTION, AuditLog.entity_id == did)
                .order_by(AuditLog.log_id).all())
        values = [(log.old_value, log.new_value) for log in logs]
    finally:
        db.close()
    assert len(values) == 2
    (old1, new1), (old2, new2) = values
    assert old1["cause"] is None and new1["cause"] == "Damaged" and new1["note"] == "Wet sacks"
    assert old2["cause"] == "Damaged" and old2["note"] == "Wet sacks"
    assert new2["cause"] == "Lost in transit" and new2["reviewed_by"] == "csws Test"
    assert new2["short_lines"] == [{"item_id": 1, "expected": 50, "received": 40}]
    text = str(values).lower()
    assert "handover" not in text and "signature" not in text and "hash" not in text


# --------------------------------------------- 409 when there is nothing to review
def test_not_confirmed_or_not_short_is_409(api):
    client, t = api
    body = {"cause": "Damaged"}
    waiting, _ = _arrived(client, t)
    r = _review(client, t, waiting, body)
    assert r.status_code == 409 and "Only a delivery the barangay confirmed" in r.json()["detail"]
    exact, _ = _confirmed(client, t, 30, 30)
    r = _review(client, t, exact, body)
    assert r.status_code == 409 and "no short line" in r.json()["detail"]
    over, _ = _confirmed(client, t, 20, 25)
    assert _review(client, t, over, body).status_code == 409
    assert _review(client, t, 999999, body).status_code == 404


# ----------------------------------------------- the reviewed filter, paging
def test_the_reviewed_filter_and_paging(api):
    client, t = api
    first, _ = _confirmed(client, t, 50, 40)
    second, _ = _confirmed(client, t, 50, 45)
    ok(_review(client, t, first, {"cause": "Damaged"}))

    assert _ids(ok(client.get(URL, headers=t["csws"], params={"reviewed": "true"}))) == [first]
    assert _ids(ok(client.get(URL, headers=t["csws"], params={"reviewed": "false"}))) == [second]
    assert _ids(ok(client.get(URL, headers=t["csws"]))) == [second, first]     # newest first
    page = client.get(URL, headers=t["csws"], params={"limit": 1, "offset": 1})
    assert page.headers["X-Total-Count"] == "2" and _ids(page.json()) == [first]
    assert client.get(URL, headers=t["csws"], params={"reviewed": "maybe"}).status_code == 422
