"""
Ivan (donor Reports tab): GET /donations/mine "deliveries" lists the
deliveries going to the reports this user donated to, newest first, without
cancelled ones and without deliveries to other reports. No schema change.
"""
from datetime import datetime, timedelta, timezone

import core.database as database
from models.delivery import Delivery, DeliveryItem, Receipt
from models.user_rbac_model import User
from tests.test_donation_batch import LINE, _report
from tests.test_role_flows import api, ok  # noqa: F401  (fixture)


def _delivery(db, report_id, status, when, csws_id, brgy_id=1):
    d = Delivery(
        report_id=report_id, destination_barangay_id=brgy_id,
        handled_by_user_id=csws_id, status=status, delivery_date=when,
    )
    db.add(d)
    db.flush()
    db.add(DeliveryItem(delivery_id=d.delivery_id, item_id=1, quantity=5))
    return d


def test_mine_lists_deliveries_to_supported_reports(api):
    client, t = api
    mine_report = _report(client, t)
    other_report = _report(client, t)
    ok(client.post("/donations/batch", headers=t["donor"], json={
        "report_id": mine_report, "handover_method": "Drop Off", "items": [LINE],
    }), 201)

    now = datetime.now(timezone.utc)
    db = database.SessionLocal()
    try:
        csws = db.query(User).filter(User.email == "csws.test@example.com").one().user_id
        _delivery(db, mine_report, "In Transit", now - timedelta(days=2), csws)
        done = _delivery(db, mine_report, "Confirmed", now - timedelta(days=1), csws)
        db.add(Receipt(delivery_id=done.delivery_id, received_by_user_id=csws))
        _delivery(db, mine_report, "Cancelled", now, csws)        # left out
        _delivery(db, other_report, "In Transit", now, csws)      # not this donor's
        db.commit()
    finally:
        db.close()

    rows = ok(client.get("/donations/mine", headers=t["donor"]))["deliveries"]
    assert [r["status"] for r in rows] == ["Confirmed", "In Transit"]  # newest first
    assert all(r["report_id"] == mine_report for r in rows)
    first = rows[0]
    assert first["items_summary"] == "Rice"
    assert first["total_quantity"] == 5
    assert first["barangay"] == "Barangay Test"
    assert first["report_label"] == "Flood in Barangay Test"
    assert first["confirmed_at"] is not None and rows[1]["confirmed_at"] is None


def test_mine_has_no_deliveries_without_donations(api):
    client, t = api
    assert ok(client.get("/donations/mine", headers=t["donor"]))["deliveries"] == []
