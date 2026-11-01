"""F-23(c): a delivery's history names staff by their display name, not their
email, so a barangay rep never sees staff email addresses."""
import core.database as database
from models.user_rbac_model import User
from tests.test_runthrough_gaps import _deliver
from tests.test_delivery_allocation import _give
from tests.test_donation_batch import _report
from tests.test_pickup_days_and_runs import _activate_everyone
from tests.test_role_flows import ACCOUNTS, api, ok  # noqa: F401  (fixture)


def _name_and_email(key):
    email = ACCOUNTS[key][0]
    db = database.SessionLocal()
    try:
        u = db.query(User).filter(User.email == email).one()
        return f"{u.first_name} {u.last_name}".strip(), email
    finally:
        db.close()


def test_history_shows_staff_names_not_emails_to_the_barangay(api):
    client, t = api
    _activate_everyone()
    rid = _report(client, t)
    _give(client, t, rid, 20)
    did = _deliver(client, t, rid)                       # prepared by CSWS
    ok(client.post(f"/deliveries/{did}/advance", headers=t["csws"]))   # In Transit
    ok(client.post(f"/deliveries/{did}/advance", headers=t["csws"]))   # Delivered
    ok(client.post(f"/deliveries/{did}/confirm-receipt", headers=t["brgy"],
                   json={"remarks": "Complete"}), 201)

    csws_name, csws_email = _name_and_email("csws")
    brgy_name, brgy_email = _name_and_email("brgy")

    # The barangay rep opens the history of a delivery to their barangay.
    hist = ok(client.get(f"/deliveries/{did}/history", headers=t["brgy"]))["history"]
    who = [row["by"] for row in hist]
    assert csws_name in who and brgy_name in who         # names are shown
    assert all("@" not in str(row["by"]) for row in hist)  # never an email
    assert csws_email not in who and brgy_email not in who

    # Same for CSWS and the Administrator (consistent, and still no emails).
    for staff in ("csws", "admin"):
        rows = ok(client.get(f"/deliveries/{did}/history", headers=t[staff]))["history"]
        assert all("@" not in str(r["by"]) for r in rows)


def test_history_falls_back_to_email_when_the_name_is_blank(api):
    client, t = api
    _activate_everyone()
    rid = _report(client, t)
    _give(client, t, rid, 20)
    did = _deliver(client, t, rid)

    db = database.SessionLocal()                          # a staff account with no name
    try:
        u = db.query(User).filter(User.email == ACCOUNTS["csws"][0]).one()
        u.first_name, u.last_name = "", ""
        db.commit()
    finally:
        db.close()

    rows = ok(client.get(f"/deliveries/{did}/history", headers=t["csws"]))["history"]
    assert any(r["by"] == ACCOUNTS["csws"][0] for r in rows)   # email fallback
