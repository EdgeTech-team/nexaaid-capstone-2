"""
I1 (Module 1.2): internal users change the temporary password the
Administrator gave them. Login tells the app (user.must_change_password),
and POST /auth/change-password clears the flag.
"""
import core.database as database
from models.audit_log_model import AuditLog
from tests.reg_helpers import STRONG_PASSWORD, upload
from tests.test_role_flows import PASSWORD, api, ok  # noqa: F401  (fixture)

URL = "/auth/change-password"
EMAIL = "lorna@csws.gov.ph"
NEW_PASSWORD = "Bagong#Pass2026"   # passes the old and the relaxed (D2) rule


def _create_staff(client, t):
    card = upload(client, "employee_id_card", headers=t["admin"])
    ok(client.post("/admin/users", headers=t["admin"], json={
        "first_name": "Lorna", "last_name": "Diaz", "email": EMAIL,
        "password": STRONG_PASSWORD, "contact_number": "09181112222",
        "role_name": "CSWS Main Office", "employee_id": "CSWS-0777",
        "employee_id_card": {"file_id": card["file_id"]},
    }), 201)


def _login(client, password):
    return client.post("/auth/login", json={"email": EMAIL, "password": password})


def test_new_internal_account_must_change_its_temporary_password(api):
    client, t = api
    _create_staff(client, t)

    r = ok(_login(client, STRONG_PASSWORD))
    assert r["user"]["must_change_password"] is True
    h = {"Authorization": f"Bearer {r['access_token']}"}
    assert ok(client.get("/auth/me", headers=h))["must_change_password"] is True

    def change(current, new, confirm=None):
        return client.post(URL, headers=h, json={
            "current_password": current, "new_password": new,
            "confirm_password": new if confirm is None else confirm,
        })

    assert change("Wrong#Pass2026", NEW_PASSWORD).status_code == 400          # wrong current
    assert change(STRONG_PASSWORD, NEW_PASSWORD, "Other#Pass2026").status_code == 422  # mismatch
    assert change(STRONG_PASSWORD, STRONG_PASSWORD).status_code == 422        # same as current
    assert change(STRONG_PASSWORD, "short").status_code == 422                # too weak
    assert ok(_login(client, STRONG_PASSWORD))["user"]["must_change_password"] is True

    res = ok(change(STRONG_PASSWORD, NEW_PASSWORD))
    assert res["must_change_password"] is False
    # The same session keeps working, and the flag is gone.
    assert ok(client.get("/auth/me", headers=h))["must_change_password"] is False
    assert _login(client, STRONG_PASSWORD).status_code == 401
    assert ok(_login(client, NEW_PASSWORD))["user"]["must_change_password"] is False

    db = database.SessionLocal()
    try:
        log = db.query(AuditLog).filter(AuditLog.action == "CHANGE PASSWORD").one()
        assert log.old_value["must_change_password"] is True
        assert log.new_value["must_change_password"] is False
        text = f"{log.old_value}{log.new_value}"
        assert STRONG_PASSWORD not in text and NEW_PASSWORD not in text
    finally:
        db.close()


def test_needs_login_and_self_registered_users_are_not_flagged(api):
    client, t = api
    body = {"current_password": PASSWORD, "new_password": NEW_PASSWORD,
            "confirm_password": NEW_PASSWORD}
    assert client.post(URL, json=body).status_code == 401
    assert ok(client.get("/auth/me", headers=t["donor"]))["must_change_password"] is False