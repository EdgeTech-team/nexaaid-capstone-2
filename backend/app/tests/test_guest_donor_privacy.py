"""
F-09: guest donor data. A guest must agree to the processing of their data
(RA 10173); the API refuses a guest donation without it, on both donation
endpoints, and records when consent was given. Guest input is validated like
a registration. Staff who handle donations see the guest's contact details;
barangay representatives do not.
Real auth stack: the `api` fixture of tests/test_role_flows.py.
"""
import json

from core import database
from models.guest_donor_model import GuestDonor
from tests.test_donation_batch import LINE, _report
from tests.test_role_flows import api, ok  # noqa: F401  (fixture)

GUEST = {"full_name": "Gina Guest", "contact_number": "0917 123 4567", "consent": True}


def _batch(rid, **guest):
    return {"report_id": rid, "handover_method": "Drop Off", "items": [LINE],
            "guest_donor": {**GUEST, **guest}}


def _single(rid, **guest):
    return {"report_id": rid, "item_id": 1, "packaging": "Box", "handover_method": "Drop Off",
            "quantity": 1, "guest_donor": {**GUEST, **guest}}


def _guests():
    db = database.SessionLocal()
    try:
        return db.query(GuestDonor).all()
    finally:
        db.close()


def test_guest_donation_needs_consent_on_both_endpoints(api):
    client, t = api
    rid = _report(client, t)
    for path, body in (("/donations/batch", _batch), ("/donations/", _single)):
        r = client.post(path, json=body(rid, consent=False))
        assert r.status_code == 422 and "RA 10173" in r.text, path
        missing = body(rid)
        del missing["guest_donor"]["consent"]
        assert client.post(path, json=missing).status_code == 422, path
    assert _guests() == []                                    # nothing saved without consent


def test_guest_input_is_validated_on_both_endpoints(api):
    client, t = api
    rid = _report(client, t)
    bad = [{"full_name": ""}, {"full_name": "G"}, {"full_name": "A" * 101},
           {"full_name": "R2-D2"}, {"contact_number": "0917"},
           {"contact_number": "1" * 40}, {"email": "not-an-email"}]
    for guest in bad:
        assert client.post("/donations/batch", json=_batch(rid, **guest)).status_code == 422, guest
        assert client.post("/donations/", json=_single(rid, **guest)).status_code == 422, guest
    assert _guests() == []


def test_valid_guest_donation_is_saved_with_consent_time(api):
    client, t = api
    rid = _report(client, t)
    b = ok(client.post("/donations/batch", json=_batch(rid, email="Gina@Example.com")), 201)
    ok(client.post("/donations/", json=_single(rid)))         # the older endpoint works too
    rows = _guests()
    assert len(rows) == 2
    assert all(g.consent_at is not None for g in rows)
    first = next(g for g in rows if g.email)
    assert (first.full_name, first.contact_number, first.email) == (
        "Gina Guest", "09171234567", "gina@example.com")
    # Staff handling donations see the contact details; the QR still works.
    staff = ok(client.get(f"/donations/by-batch/{b['batch_reference']}", headers=t["csws"]))
    assert staff["donor"] == "Gina Guest (guest)" and staff["donor_contact"] == "09171234567"
    assert ok(client.get(f"/donations/batch/{b['batch_reference']}/qr"))["qr_image_base64"]
    # Barangay representatives follow the goods, not who gave them.
    records = ok(client.get("/donations/records", headers=t["brgy"]))
    assert "Gina" not in json.dumps(records) and "09171234567" not in json.dumps(records)
