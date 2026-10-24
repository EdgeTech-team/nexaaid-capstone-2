"""F-17: a failed guest cancellation always gets the same answer and stops
after 5 wrong tries per donation in 15 minutes; staff are never limited.
GET /donations/{id}/qr is for the owner and CSWS / Admin only. The cron
token is compared in constant time."""
import core.auth as auth
from tests.test_donation_batch import _report
from tests.test_donation_expiry import _entry, _rows
from tests.test_role_flows import api, ok  # noqa: F401  (fixture)

GUEST = {"full_name": "Guest", "contact_number": "0917 123 4567", "consent": True}
FAILED = "Log in, or enter the phone number you used when donating."
WRONG = {"contact_number": "09181234567"}
RIGHT = {"contact_number": "09171234567"}


def _guest_ref(client, rid):
    return _entry(client, {}, rid, guest_donor=GUEST)["batch_reference"]


def test_every_failed_guest_attempt_gets_the_same_answer(api):
    client, t = api
    rid = _report(client, t)
    ref = _guest_ref(client, rid)
    donor_ref = _entry(client, t["donor"], rid)["batch_reference"]
    for target, body in ((ref, WRONG), (ref, {}), (ref, {"contact_number": "hello"}),
                         (donor_ref, RIGHT)):
        r = client.post(f"/donations/entries/{target}/cancel", json=body)
        assert r.status_code == 403 and r.json()["detail"] == FAILED


def test_guest_phone_check_stops_after_five_wrong_tries(api, monkeypatch):
    client, t = api
    rid = _report(client, t)
    ref = _guest_ref(client, rid)
    url = f"/donations/entries/{ref}/cancel"
    for _ in range(5):
        assert client.post(url, json=WRONG).status_code == 403
    # Even the right number now waits, by any spelling of the reference.
    blocked = client.post(url, json=RIGHT)
    assert blocked.status_code == 429 and blocked.headers["Retry-After"]
    assert client.post(f"/donations/entries/{ref.lower()}/cancel", json=RIGHT).status_code == 429
    # The limit is per donation: another guest donation is not affected.
    ok(client.post(f"/donations/entries/{_guest_ref(client, rid)}/cancel", json=RIGHT))
    # 15 minutes later the guest can cancel.
    later = auth._now() + auth.LOGIN_WINDOW_SECONDS + 1
    monkeypatch.setattr(auth, "_now", lambda: later)
    ok(client.post(url, json=RIGHT))
    assert _rows(ref)[0].status == "Cancelled"


def test_staff_are_never_limited_by_guest_tries(api):
    client, t = api
    rid = _report(client, t)
    ref = _guest_ref(client, rid)
    for _ in range(6):
        client.post(f"/donations/entries/{ref}/cancel", json=WRONG)
    # The guest phoned CSWS: CSWS cancels for them while the phone check waits.
    out = ok(client.post(f"/donations/entries/{ref}/cancel", headers=t["csws"],
                         json={"reason": "Guest called the office"}))
    assert out["status"] == "Cancelled"


def test_donation_qr_by_id_is_for_the_owner_and_csws_only(api):
    client, t = api
    rid = _report(client, t)
    mine = _entry(client, t["donor"], rid)["items"][0]["donation_id"]
    guest = _entry(client, {}, rid, guest_donor=GUEST)["items"][0]["donation_id"]
    for headers in ({}, t["unit"], t["cmo"], t["brgy"]):
        r = client.get(f"/donations/{mine}/qr", headers=headers)
        assert r.status_code == 404 and r.json()["detail"] == "Donation not found"
    assert client.get("/donations/999999/qr", headers=t["csws"]).status_code == 404
    assert ok(client.get(f"/donations/{mine}/qr", headers=t["donor"]))["batch_reference"]
    for staff in ("csws", "admin"):
        assert ok(client.get(f"/donations/{guest}/qr", headers=t[staff]))["qr_image_base64"]
    assert client.get(f"/donations/{guest}/qr", headers=t["donor"]).status_code == 404


def test_cron_token_needs_the_exact_value(api, monkeypatch):
    client, t = api
    monkeypatch.setenv("DONATION_CRON_TOKEN", "s3cret-token")
    for bad in ("s3cret", "s3cret-token-and-more", "S3CRET-TOKEN", b"\xf1"):
        assert client.post("/donations/expiry/run", headers={"X-Cron-Token": bad}).status_code == 403
    ok(client.post("/donations/expiry/run", headers={"X-Cron-Token": "s3cret-token"}))
    monkeypatch.setenv("DONATION_CRON_TOKEN", "")
    assert client.post("/donations/expiry/run", headers={"X-Cron-Token": ""}).status_code == 403
