"""
F-10: a token stops working once the password changes (change, reset), and
an account still on its temporary password can only change it. /auth/me
and /health/secure stay open for it because the app calls them at login.

Real auth stack: the `api` fixture of tests/test_role_flows.py.
"""
import jwt

import core.database as database
from core.config import settings
from models.user_rbac_model import User

from tests.reg_helpers import STRONG_PASSWORD
from tests.test_change_password import EMAIL, NEW_PASSWORD, URL, _create_staff

from tests.test_lookups_access import _report
from tests.test_password_reset_limits import DONOR, _capture, _code, _reset
from tests.test_password_reset_limits import NEW_PASSWORD as RESET_PASSWORD
from tests.test_role_flows import ACCOUNTS, PASSWORD, api, ok  # noqa: F401  (fixture)

STALE = "Could not validate credentials (invalid or expired token)"
TEMP = "Change your temporary password first (Profile > Change password)."


def _login(client, email, password):
    return ok(client.post("/token", data={"username": email, "password": password}))


def _bearer(res):
    return {"Authorization": f"Bearer {res['access_token']}"}


def _change(client, headers, current, new):
    return client.post(URL, headers=headers, json={
        "current_password": current, "new_password": new, "confirm_password": new})


def _set(email, **fields):
    db = database.SessionLocal()
    try:
        user = db.query(User).filter(User.email == email).one()
        for k, v in fields.items():
            setattr(user, k, v)
        db.commit()
    finally:
        db.close()


def test_old_tokens_stop_working_after_a_password_change(api):
    client, t = api
    email = ACCOUNTS["admin"][0]
    _report(client, t)                                   # something only staff see in /lookups
    laptop = t["admin"]
    phone = _bearer(_login(client, email, PASSWORD))     # another device, or a stolen token

    fresh = _bearer(ok(_change(client, laptop, PASSWORD, NEW_PASSWORD)))
    for old in (laptop, phone):
        for path in ("/admin/users", "/auth/me", "/health/secure"):
            r = client.get(path, headers=old)
            assert (r.status_code, r.json()["detail"]) == (401, STALE), path
        # Pages that allow guests answer an old token as a guest.
        assert ok(client.get("/lookups", headers=old)) == ok(client.get("/lookups"))
    # The device that changed the password carries on with its new token.
    assert ok(client.get("/admin/users", headers=fresh))
    assert ok(client.get("/lookups", headers=fresh))["reports"]
    # Signing in again: the old password fails, the new one works.
    assert client.post("/token", data={"username": email, "password": PASSWORD}).status_code == 401
    assert ok(client.get("/admin/users", headers=_bearer(_login(client, email, NEW_PASSWORD))))


def test_a_password_reset_ends_every_session(api, monkeypatch):
    client, t = api
    sent = _capture(monkeypatch)
    old = t["donor"]
    assert ok(client.get("/donations/mine", headers=old))
    ok(client.post("/auth/forgot-password", json={"email": DONOR}))
    ok(client.post("/auth/reset-password", json=_reset(_code(sent[-1]))))

    r = client.get("/donations/mine", headers=old)
    assert (r.status_code, r.json()["detail"]) == (401, STALE)
    assert ok(client.get("/donations/mine", headers=_bearer(_login(client, DONOR, RESET_PASSWORD))))


def test_a_temporary_password_only_opens_the_change_password_screen(api):
    client, t = api
    _report(client, t)
    _create_staff(client, t)                             # CSWS Main Office, temporary password
    temp = _bearer(_login(client, EMAIL, STRONG_PASSWORD))

    # Allowed: what the app needs to show the forced change screen.
    assert ok(client.get("/auth/me", headers=temp))["must_change_password"] is True
    assert ok(client.get("/health/secure", headers=temp))["role"] == "CSWS Main Office"
    # Everything else is refused, even when the API is called directly.
    for method, path, body in (
        ("get", "/logistics/requests", None),
        ("get", "/reports/validated", None),
        ("get", "/notifications/", None),
        ("post", "/donations/receive", {"donation_id": 1, "actual_quantity": 1}),
    ):
        r = client.request(method, path, headers=temp, json=body)
        assert (r.status_code, r.json()["detail"]) == (403, TEMP), path
    # Public pages answer as for a guest: nothing role-specific.
    assert ok(client.get("/lookups", headers=temp)) == ok(client.get("/lookups"))

    # The password rules still apply to the new password.
    assert _change(client, temp, STRONG_PASSWORD, "short").status_code == 422
    res = ok(_change(client, temp, STRONG_PASSWORD, NEW_PASSWORD))
    assert res["must_change_password"] is False
    assert res["user"]["must_change_password"] is False
    staff = _bearer(res)
    assert ok(client.get("/logistics/requests", headers=staff)) == []
    assert ok(client.get("/lookups", headers=staff))["reports"]
    # The temporary-password token is now an old token.
    assert client.get("/auth/me", headers=temp).status_code == 401


def test_ordinary_accounts_roles_and_deactivation_are_unchanged(api):
    client, t = api
    for who in ACCOUNTS:
        assert ok(client.get("/auth/me", headers=t[who]))["must_change_password"] is False, who
    assert ok(client.get("/admin/users", headers=t["admin"]))
    assert client.get("/admin/users", headers=t["donor"]).status_code == 403    # roles unchanged
    # A deactivated account is refused first, temporary password or not.
    _set(ACCOUNTS["csws"][0], must_change_password=True, is_active=False)
    for path in ("/auth/me", "/logistics/requests", "/lookups"):
        r = client.get(path, headers=t["csws"])
        assert (r.status_code, r.json()["detail"]) == (403, "Account is deactivated"), path


def test_tokens_carry_no_password_data_and_old_style_tokens_are_refused(api):
    client, t = api
    token = _login(client, DONOR, PASSWORD)["access_token"]
    claims = jwt.decode(token, options={"verify_signature": False})
    assert set(claims) == {"sub", "uid", "role", "pwd", "exp"}
    assert len(claims["pwd"]) == 16 and "$2" not in str(claims)     # no bcrypt hash
    # A token from before F-10 (same claims, no stamp) is refused.
    legacy = jwt.encode({k: v for k, v in claims.items() if k != "pwd"},
                        settings.SECRET_KEY, algorithm=settings.ALGORITHM)
    r = client.get("/auth/me", headers={"Authorization": f"Bearer {legacy}"})
    assert (r.status_code, r.json()["detail"]) == (401, STALE)
