"""
F-08: deleting an account also removes the person's data where it was
copied (audit entries, the organization's contact details, donation pickup
locations), while every record and audit entry stays.
Real auth stack: the `api` fixture of tests/test_role_flows.py.
"""
import json

from core import database
from models.audit_log_model import AuditLog
from models.organization_model import Organization
from models.physical_donation_model import PhysicalDonation
from models.upload_model import Upload
from tests.reg_helpers import STRONG_PASSWORD, donor_payload, org_payload
from tests.test_donation_batch import _report
from tests.test_pickup_days_and_runs import _door
from tests.test_role_flows import ACCOUNTS, api, ok  # noqa: F401  (fixture)

DONOR = "privacy.donor@example.com"
ORG = "privacy.org@example.com"


def _uid(client, t, email):
    return next(u["user_id"] for u in ok(client.get("/admin/users", headers=t["admin"]))
                if u["email"] == email)


def _login(client, email):
    tok = ok(client.post("/token", data={"username": email, "password": STRONG_PASSWORD}))
    return {"Authorization": f"Bearer {tok['access_token']}"}


def _delete(client, t, uid):
    ok(client.patch(f"/admin/users/{uid}", headers=t["admin"],
                    json={"is_active": False, "deactivation_reason": "Asked to leave, call 09181112222"}))
    ok(client.delete(f"/admin/users/{uid}", headers=t["admin"]))


def test_donor_deletion_removes_copies_but_keeps_records(api):
    client, t = api
    ok(client.post("/auth/register/donor", json=donor_payload(client, DONOR)), 201)
    donor = _login(client, DONOR)
    uid = _uid(client, t, DONOR)
    rid = _report(client, t)
    batch = ok(client.post("/donations/batch", headers=donor, json=_door(rid, [3])), 201)
    ok(client.patch(f"/admin/users/{uid}", headers=t["admin"], json={"contact_number": "09181112222"}))
    db = database.SessionLocal()
    try:   # an entry the donor wrote about its donation, with its home pin (as EDIT DONATION does)
        did = db.query(PhysicalDonation).filter(PhysicalDonation.user_id == uid).first().donation_id
        db.add(AuditLog(user_id=uid, action="EDIT DONATION", entity_type="physical_donations",
                        entity_id=did, ip_address="203.0.113.7",
                        old_value={"handover_method": "Door to Door", "pickup_lat": 10.3236,
                                   "pickup_lng": 123.943}))
        db.commit()
    finally:
        db.close()

    _delete(client, t, uid)

    db = database.SessionLocal()
    try:
        logs = db.query(AuditLog).filter(
            ((AuditLog.entity_type == "users") & (AuditLog.entity_id == uid)) | (AuditLog.user_id == uid)
        ).all()
        text = json.dumps([[l.old_value, l.new_value] for l in logs])
        for personal in (DONOR, "09181112222", "09171234567", "call 09181112222", "10.3236"):
            assert personal not in text, personal
        actions = {l.action for l in logs}
        assert {"REGISTER DONOR", "UPDATE ACCOUNT", "EDIT DONATION", "DELETE ACCOUNT"} <= actions  # entries kept
        reg = next(l for l in logs if l.action == "REGISTER DONOR")
        assert reg.new_value["email"] == "[deleted]" and reg.new_value["consent_ra10173"] is True
        edit = next(l for l in logs if l.action == "EDIT DONATION")
        assert edit.old_value["handover_method"] == "Door to Door" and edit.ip_address is None
        upd = next(l for l in logs if l.action == "UPDATE ACCOUNT")
        assert upd.ip_address == "testclient"                       # the admin's own IP is kept
        dele = next(l for l in logs if l.action == "DELETE ACCOUNT")
        assert dele.old_value == {"role": "Individual Donor"}
        assert dele.new_value["redacted_audit_entries"] >= 3 and dele.new_value["cleared_pickups"] >= 1
        # Donations stay as relief records; only the home location is gone.
        rows = db.query(PhysicalDonation).filter(PhysicalDonation.batch_reference == batch["batch_reference"]).all()
        assert rows and all(r.status == "Pending" and r.quantity > 0 for r in rows)
        assert all(r.pickup_address is None and r.pickup_lat is None and r.pickup_landmark is None
                   for r in rows)
    finally:
        db.close()


def test_org_deletion_anonymizes_contact_keeps_the_organization(api):
    client, t = api
    ok(client.post("/auth/register/organization", json=org_payload(client, ORG)), 201)
    uid = _uid(client, t, ORG)
    org = next(o for o in ok(client.get("/admin/organizations", headers=t["admin"]))
               if o["contact_email"] == ORG)

    _delete(client, t, uid)

    db = database.SessionLocal()
    try:
        row = db.get(Organization, org["organization_id"])
        assert (row.org_name, row.organization_type, row.status) == (
            org["org_name"], org["organization_type"], org["status"])          # kept
        assert row.contact_person == "Deleted contact"
        assert row.contact_email.endswith("@deleted.nexaaid.invalid")
        assert row.address is None and row.registration_no is None and row.legitimacy_document_url is None
        assert db.query(Upload).filter(Upload.owner_user_id == uid).count() == 0
        reg = db.query(AuditLog).filter(AuditLog.action == "REGISTER ORGANIZATION").one()
        assert reg.new_value["org_name"] == org["org_name"] and reg.new_value["email"] == "[deleted]"
    finally:
        db.close()
    # The same registration number and email can register again.
    ok(client.post("/auth/register/organization", json=org_payload(client, ORG)), 201)


def test_staff_deletion_keeps_what_they_did_to_other_records(api):
    client, t = api
    rid = _report(client, t)
    did = ok(client.post("/donations/", headers=t["donor"], json={
        "report_id": rid, "item_id": 1, "packaging": "Box",
        "handover_method": "Drop Off", "quantity": 5}))["donation_id"]
    ok(client.post("/donations/receive", headers=t["csws"],
                   json={"donation_id": did, "actual_quantity": 5}))
    csws = _uid(client, t, ACCOUNTS["csws"][0])

    _delete(client, t, csws)

    db = database.SessionLocal()
    try:
        recv = db.query(AuditLog).filter(AuditLog.action == "RECEIVE DONATION").one()
        assert recv.user_id == csws and recv.entity_id == did               # attribution kept
        assert recv.new_value["actual_quantity"] == 5                       # values kept
        # The other donor's donation and account are untouched.
        assert db.get(PhysicalDonation, did).status == "Received"
    finally:
        db.close()
    assert ok(client.get("/health/secure", headers=t["donor"]))["user"] == ACCOUNTS["donor"][0]
