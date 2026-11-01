"""Oct 17 run-through of Appendix H (1.1 ... 9.7): the gaps it found.

Each hand-off now reaches the next person, staff cannot donate, and a CMO
acknowledgement is final (task #10, Oct 23: no undo at all).
"""
from datetime import datetime, timedelta, timezone

import api.v1.deliveries as deliveries
from tests.test_delivery_allocation import _give
from tests.test_donation_batch import _report
from tests.test_pickup_days_and_runs import _activate_everyone
from tests.test_role_flows import api, ok  # noqa: F401  (fixture)


def _types(client, headers):
    return [n["type"] for n in ok(client.get("/notifications/", headers=headers))["items"]]


def _deliver(client, t, rid, refs=None, when="2026-10-20T08:00:00"):
    body = {"report_id": rid, "destination_barangay_id": 1, "delivery_date": when}
    if refs is not None:
        body["batch_references"] = refs
    return ok(client.post("/deliveries/", headers=t["csws"], json=body), 201)["delivery_id"]


def test_staff_accounts_cannot_submit_donations(api):
    """Appendix H 4.1 / 4.2: donors, organizations and guests give."""
    client, t = api
    rid = _report(client, t)
    body = {"report_id": rid, "handover_method": "Drop Off",
            "items": [{"item_id": 1, "packaging": "Sack", "quantity": 1}]}
    for who in ("csws", "admin", "cmo", "unit", "drrmo", "brgy"):
        r = client.post("/donations/batch", headers=t[who], json=body)
        assert r.status_code == 403, who
    assert client.post("/donations/batch", headers=t["donor"], json=body).status_code == 201
    assert client.post("/donations/batch", json={**body, "guest_donor": {
    "full_name": "Gina Guest", "contact_number": "09179999999", "consent": True}}).status_code == 201

def test_a_cmo_acknowledgement_is_final(api):
    """Task #10 (Oct 23): no undo, before or after a delivery. The old
    revert endpoints are gone from the API, not just the button."""
    client, t = api
    _activate_everyone()
    rid = _report(client, t)
    a, b = _give(client, t, rid, 10), _give(client, t, rid, 5)

    # Not on a delivery yet: still no undo, and nobody is told otherwise.
    assert client.post(f"/cmo/entries/{b['batch_reference']}/revert",
                       headers=t["cmo"]).status_code in (404, 405)
    one = b["items"][0]["donation_id"]
    assert client.post(f"/cmo/donations/{one}/revert", headers=t["cmo"]).status_code in (404, 405)
    assert "donation_unacknowledged" not in _types(client, t["donor"])
    pending = ok(client.get("/cmo/entries/pending", headers=t["cmo"]))
    assert b["batch_reference"] not in [e["batch_reference"] for e in pending]

    # On a delivery, cancelled or not, it stays acknowledged.
    did = _deliver(client, t, rid, [a["batch_reference"]])
    ok(client.post(f"/deliveries/{did}/cancel", headers=t["csws"], json={"reason": "Wrong report"}))
    assert client.post(f"/cmo/entries/{a['batch_reference']}/revert",
                       headers=t["cmo"]).status_code in (404, 405)
    acked = ok(client.get("/cmo/entries/acknowledged", headers=t["cmo"]))
    assert {a["batch_reference"], b["batch_reference"]} <= {e["batch_reference"] for e in acked}


def test_donors_and_the_barangay_follow_the_delivery(api, monkeypatch):
    client, t = api
    _activate_everyone()
    rid = _report(client, t)
    b = _give(client, t, rid, 20)
    before = len(_types(client, t["donor"]))
    did = _deliver(client, t, rid)
    assert "delivery_prepared" in _types(client, t["brgy"])          # the barangay gets ready
    assert "delivery_prepared" not in _types(client, t["brgy2"])     # not another barangay

    tomorrow = datetime.now(timezone.utc) + timedelta(days=1)
    ok(client.post(f"/deliveries/{did}/reschedule", headers=t["csws"],
                   json={"delivery_date": tomorrow.isoformat(), "reason": "Rain"}))
    monkeypatch.setattr(deliveries, "now_utc", lambda: tomorrow)        # the new day comes
    ok(client.post(f"/deliveries/{did}/advance", headers=t["csws"]))   # In Transit
    # Transport is asked for while Preparing, not once the truck has left.
    assert client.post("/logistics/requests", headers=t["csws"], json={
        "delivery_id": did, "trucks": 1, "drivers": 1, "volunteers": 0}).status_code == 409
    ok(client.post(f"/deliveries/{did}/advance", headers=t["csws"]))   # Delivered
    ok(client.post(f"/deliveries/{did}/confirm-receipt", headers=t["brgy"], json={"remarks": "Complete"}), 201)
    got = _types(client, t["donor"])[: len(_types(client, t["donor"])) - before]
    for event in ("donation_delivery_rescheduled", "donation_in_transit", "donation_delivered",
                  "donation_barangay_confirmed"):
        assert got.count(event) == 1, (event, got)                  # one per entry
    note = next(n for n in ok(client.get("/notifications/", headers=t["donor"]))["items"]
                if n["type"] == "donation_in_transit")
    assert b["batch_reference"] in note["message"] and note["entity_type"] == "donation"

    # Confirming receipt is also the barangay's acknowledgement (one tap,
    # Oct 20): its notice reaches Main Office and the reporter.
    assert "delivery_receipt_confirmed" in _types(client, t["csws"])
    assert "delivery_receipt_confirmed" in _types(client, t["unit"])
    assert ok(client.get(f"/deliveries/{did}/history", headers=t["csws"]))["acknowledged"]


def test_a_cancelled_delivery_tells_its_donors(api):
    client, t = api
    _activate_everyone()
    rid = _report(client, t)
    _give(client, t, rid, 4)
    did = _deliver(client, t, rid)
    ok(client.post(f"/deliveries/{did}/cancel", headers=t["csws"], json={"reason": "No truck"}))
    assert "donation_delivery_cancelled" in _types(client, t["donor"])


def test_main_office_hears_when_drrmo_completes_the_support(api):
    client, t = api
    _activate_everyone()
    rid = _report(client, t)
    _give(client, t, rid, 6)
    did = _deliver(client, t, rid, when="2026-01-05T08:00:00")
    req = ok(client.post("/logistics/requests", headers=t["csws"], json={"delivery_id": did, "trucks": 1}), 201)
    ok(client.patch(f"/drrmo/requests/{req['request_id']}/accept", headers=t["drrmo"], json={}))
    # Testing fix 7.5: In Transit (8.1), then the barangay's receipt (8.2).
    # Advisor (Oct 24): DRRMO marks it In Transit when it picks up the goods.
    ok(client.post(f"/drrmo/requests/{req['request_id']}/picked-up", headers=t["drrmo"]))
    ok(client.post(f"/drrmo/requests/{req['request_id']}/delivered", headers=t["drrmo"]))
    ok(client.post(f"/deliveries/{did}/confirm-receipt", headers=t["brgy"], json={}), 201)
    ok(client.patch(f"/drrmo/requests/{req['request_id']}/complete", headers=t["drrmo"],
                    json={"summary": "Delivered to Banilad"}))
    items = ok(client.get("/notifications/", headers=t["csws"]))["items"]
    done = [n for n in items if n["type"] == "logistics_completed"]
    assert len(done) == 1 and "Delivered to Banilad" in done[0]["message"]


def test_the_admins_hear_when_a_pending_report_is_withdrawn(api):
    client, t = api
    _activate_everyone()
    rep = ok(client.post("/reports/", headers=t["unit"], json={
        "disaster_type_id": 1, "barangay_id": 1, "affected_families": 4, "assistance_needed": "Rice"}), 201)
    ok(client.post(f"/reports/{rep['report_id']}/withdraw", headers=t["unit"]))
    assert "report_withdrawn" in _types(client, t["admin"])