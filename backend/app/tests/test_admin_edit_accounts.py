"""
UC-A1 Manage Internal Accounts (adviser items 3 and 4): the Administrator
creates and edits every field of an internal account, with the same rules
as creation.

Step 5: update details or status. Alt 3a: account not found -> 404.
Alt 5a: invalid changes are rejected (422, or 409 for a taken email /
employee ID). Employee ID card: purpose employee_id_card, uploaded by the
Administrator and handed to the staff member.
"""
import core.database as database
from core.auth import hash_password
from core.storage import get_storage
from models.audit_log_model import AuditLog
from models.upload_model import Upload
from models.user_rbac_model import User
from tests.reg_helpers import STRONG_PASSWORD, png, upload
from tests.test_role_flows import PASSWORD, api, ok  # noqa: F401  (fixture)


def _card(client, t):
    return {"file_id": upload(client, "employee_id_card", headers=t["admin"])["file_id"]}


def _new_staff(client, t, **overrides):
    body = {
        "first_name": "pedro", "last_name": "reyes", "email": "pedro@csws.gov.ph",
        "password": STRONG_PASSWORD, "contact_number": "09181234567",
        "role_name": "CSWS Main Office", "employee_id": "csws-0042",
        "employee_id_card": _card(client, t),
    }
    body.update(overrides)
    return client.post("/admin/users", headers=t["admin"], json=body)


def _id(client, t, email):
    return next(u for u in ok(client.get("/admin/users", headers=t["admin"]))
                if u["email"] == email)["user_id"]


def _login(client, email, password):
    r = client.post("/token", data={"username": email, "password": password})
    return r, ({"Authorization": f"Bearer {r.json()['access_token']}"} if r.status_code == 200 else None)


# ------------------------------------------------------------------- create

def test_create_requires_employee_id_and_card_and_hands_card_over(api):
    client, t = api
    created = ok(_new_staff(client, t), 201)
    assert created["employee_id"] == "CSWS-0042"               # stored upper case

    db = database.SessionLocal()
    try:
        u = db.get(User, created["user_id"])
        assert (u.first_name, u.last_name) == ("Pedro", "Reyes")
        card = db.query(Upload).filter(Upload.owner_user_id == u.user_id).one()
        assert card.purpose == "employee_id_card"
        log = db.query(AuditLog).filter(AuditLog.action == "CREATE ACCOUNT").one()
        assert log.new_value["employee_id"] == "CSWS-0042"
        card_url = f"/uploads/{card.file_id}"
    finally:
        db.close()

    # The staff member and Administrators can view the card; nobody else.
    _, staff = _login(client, "pedro@csws.gov.ph", STRONG_PASSWORD)
    assert client.get(card_url, headers=staff).status_code == 200
    assert client.get(card_url, headers=t["admin"]).status_code == 200
    assert client.get(card_url, headers=t["csws"]).status_code == 404


def test_create_validation(api):
    client, t = api
    cases = [
        ({"employee_id": None}, 422),
        ({"employee_id_card": None}, 422),
        ({"employee_id": "x!"}, 422),
        ({"contact_number": "1234567"}, 422),
        ({"role_name": "Administrator"}, 422),                 # internal roles only
        ({"role_name": "Barangay Receiving Representative"}, 422),  # needs a barangay
        ({"role_name": "Barangay Receiving Representative", "assigned_barangay_id": 99}, 422),
        ({"password": "short"}, 422),
    ]
    for override, code in cases:
        body = {k: v for k, v in override.items() if v is not None}
        missing = [k for k, v in override.items() if v is None]
        r = _new_staff(client, t, **body) if not missing else client.post(
            "/admin/users", headers=t["admin"],
            json={k: v for k, v in {
                "first_name": "Pedro", "last_name": "Reyes", "email": "x@csws.gov.ph",
                "password": STRONG_PASSWORD, "contact_number": "09181234567",
                "role_name": "CSWS Main Office", "employee_id": "CSWS-1",
                "employee_id_card": _card(client, t)}.items() if k not in missing})
        assert r.status_code == code, (override, r.text)

    ok(_new_staff(client, t), 201)
    r = _new_staff(client, t, email="other@csws.gov.ph")       # same employee ID
    assert r.status_code == 409 and r.json()["detail"] == "Employee ID already in use"
    r = _new_staff(client, t, email="PEDRO@csws.gov.ph", employee_id="CSWS-0099")
    assert r.status_code == 409 and r.json()["detail"] == "Email already in use"

    # The card must be an employee_id_card uploaded by this Administrator.
    anon = upload(client, "id_front")
    r = _new_staff(client, t, email="z@csws.gov.ph", employee_id="CSWS-0200",
                   employee_id_card={"file_id": anon["file_id"]})
    assert r.status_code == 400
    # Only the Administrator may upload an employee ID card.
    assert client.post("/uploads", data={"purpose": "employee_id_card"},
                       files={"file": ("c.png", png(), "image/png")},
                       headers=t["csws"]).status_code == 403
    assert client.post("/admin/users", headers=t["csws"], json={}).status_code == 403


# --------------------------------------------------------------------- edit

def test_admin_edits_every_field_and_logs_old_and_new(api):
    client, t = api
    uid = ok(_new_staff(client, t), 201)["user_id"]
    row = ok(client.patch(f"/admin/users/{uid}", headers=t["admin"], json={
        "first_name": "juan", "last_name": "dela cruz", "email": "Juan@CSWS.gov.ph",
        "contact_number": "+639991112222", "role_name": "Barangay Receiving Representative",
        "assigned_barangay_id": 2, "employee_id": "brgy-0007",
    }))
    assert row["name"] == "Juan Dela Cruz" and row["email"] == "juan@csws.gov.ph"
    assert row["contact_number"] == "09991112222" and row["employee_id"] == "BRGY-0007"
    assert row["role"] == "Barangay Receiving Representative" and row["assigned_barangay_id"] == 2

    logs = ok(client.get("/admin/audit-logs?entity_type=users", headers=t["admin"]))
    upd = next(l for l in logs if l["action"] == "UPDATE ACCOUNT" and l["entity_id"] == uid)
    assert upd["old_value"]["role"] == "CSWS Main Office"
    assert upd["new_value"]["role"] == "Barangay Receiving Representative"
    assert upd["old_value"]["employee_id"] == "CSWS-0042" and upd["new_value"]["employee_id"] == "BRGY-0007"
    assert upd["old_value"]["email"] == "pedro@csws.gov.ph"

    # The token holds the email, so the staff member logs in with the new one.
    r, _ = _login(client, "juan@csws.gov.ph", STRONG_PASSWORD)
    assert r.status_code == 200

    # Changing the role away from barangay rep clears the barangay.
    row = ok(client.patch(f"/admin/users/{uid}", headers=t["admin"],
                          json={"role_name": "CMO Representative"}))
    assert row["assigned_barangay_id"] is None


def test_edit_rules_and_errors(api):
    client, t = api
    me = _id(client, t, "testadmin@gmail.com")
    donor = _id(client, t, "donor.test@example.com")
    rep = _id(client, t, "ana.test@example.com")
    staff = ok(_new_staff(client, t), 201)["user_id"]
    patch = lambda uid, body, who="admin": client.patch(f"/admin/users/{uid}", headers=t[who], json=body)

    assert patch(99999, {"first_name": "Xavier"}).status_code == 404                  # alt 3a
    r = patch(me, {"is_active": False, "deactivation_reason": "Test reason"})
    assert r.status_code == 400 and "your own account" in r.text
    r = patch(me, {"role_name": "CSWS Main Office"})
    assert r.status_code == 400 and "your own role" in r.text

    db = database.SessionLocal()
    try:   # a second Administrator keeps the Administrator role
        db.add(User(first_name="Second", last_name="Admin", email="admin2@test.ph",
                    contact_number="09170000009", password_hash=hash_password(PASSWORD),
                    role_id=1, employee_id="ADM-0002"))
        db.commit()
    finally:
        db.close()
    admin2 = _id(client, t, "admin2@test.ph")
    assert patch(admin2, {"role_name": "CSWS Main Office"}).status_code == 422
    ok(patch(admin2, {"is_active": False, "deactivation_reason": "Test reason"}))           # another admin, one still active

    # Donors and organizations: no role, employee ID or barangay.
    assert patch(donor, {"role_name": "CSWS Main Office"}).status_code == 422
    assert patch(donor, {"employee_id": "D-0001"}).status_code == 422
    assert patch(donor, {"employee_id_card": _card(client, t)}).status_code == 422
    ok(patch(donor, {"contact_number": "09170000099"}))

    # alt 5a: invalid values.
    for body in ({"contact_number": "0917"}, {"first_name": ""}, {"first_name": None},
                 {"last_name": ""}, {"first_name": "Maria Santos", "last_name": ""},
                 {"email": "not-an-email"}, {"role_name": "Administrator"},
                 {"role_name": "Individual Donor"}, {"employee_id": "@@"},
                 {"assigned_barangay_id": 1},            # staff is not a barangay rep
                 {"role_name": "Barangay Receiving Representative"},   # no barangay
                 {"role_name": "Barangay Receiving Representative", "assigned_barangay_id": 99}):
        assert patch(staff, body).status_code == 422, body
    r = patch(staff, {"email": "ANA.test@example.com"})
    assert r.status_code == 409 and r.json()["detail"] == "Email already in use"
    ok(patch(rep, {"employee_id": "BRGY-0001", "first_name": "Ana"}))
    r = patch(staff, {"employee_id": "brgy-0001"})
    assert r.status_code == 409 and r.json()["detail"] == "Employee ID already in use"

    # Older internal accounts without an employee ID must get one on their next edit,
    # but can still be turned off / on.
    csws = _id(client, t, "csws.test@example.com")
    r = patch(csws, {"first_name": "Carla"})
    assert r.status_code == 422 and "Employee ID is required" in r.text
    ok(patch(csws, {"is_active": False, "deactivation_reason": "Test reason"}))
    ok(patch(csws, {"is_active": True}))
    ok(patch(csws, {"first_name": "Carla", "employee_id": "CSWS-0001"}))

    # Only the Administrator.
    assert patch(staff, {"first_name": "Hacked"}, who="csws").status_code == 403


def test_old_account_with_empty_last_name(api):
    """Accounts made before the name split have last_name = "" (e.g. org
    contacts). Saving an empty last name is refused (422); turning the
    account on/off still works; saving a split name fixes it."""
    client, t = api
    db = database.SessionLocal()
    try:
        db.add(User(first_name="Maria Santos", last_name="", email="old.donor@test.ph",
                    contact_number="09170000010", password_hash=hash_password(PASSWORD), role_id=2))
        db.commit()
    finally:
        db.close()
    uid = _id(client, t, "old.donor@test.ph")
    r = client.patch(f"/admin/users/{uid}", headers=t["admin"],
                     json={"first_name": "Maria Santos", "last_name": ""})
    assert r.status_code == 422 and "Last name must be 2-50 characters" in r.text
    ok(client.patch(f"/admin/users/{uid}", headers=t["admin"], json={"is_active": False, "deactivation_reason": "Test reason"}))
    row = ok(client.patch(f"/admin/users/{uid}", headers=t["admin"],
                          json={"first_name": "Maria", "last_name": "Santos", "is_active": True}))
    assert row["name"] == "Maria Santos"
    detail = ok(client.get(f"/admin/users/{uid}", headers=t["admin"]))
    assert (detail["first_name"], detail["last_name"]) == ("Maria", "Santos")


def test_replacing_the_card_deletes_the_old_one(api):
    client, t = api
    uid = ok(_new_staff(client, t), 201)["user_id"]
    db = database.SessionLocal()
    try:
        old = db.query(Upload).filter(Upload.owner_user_id == uid).one()
        old_id, old_key = old.file_id, old.storage_key
    finally:
        db.close()
    assert get_storage().path(old_key).exists()

    new_card = _card(client, t)
    ok(client.patch(f"/admin/users/{uid}", headers=t["admin"], json={"employee_id_card": new_card}))
    docs = ok(client.get(f"/admin/users/{uid}/documents", headers=t["admin"]))
    assert [d["file_id"] for d in docs] == [new_card["file_id"]]
    assert not get_storage().path(old_key).exists()                    # RA 10173
    assert client.get(f"/uploads/{old_id}", headers=t["admin"]).status_code == 404
    detail = ok(client.get(f"/admin/users/{uid}", headers=t["admin"]))
    assert detail["employee_id"] == "CSWS-0042"
