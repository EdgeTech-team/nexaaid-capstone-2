"""
F-02 / F-03: password reset and sign-in limits.
- forgot-password answers the same for every email (F-03);
- at most 5 reset codes and 10 wrong code guesses per account per hour (F-02);
- 5 wrong passwords for one login within 15 minutes make it wait (F-02).
Real auth stack: the `api` fixture of tests/test_role_flows.py.
"""
import re

import core.database as database
from models.user_rbac_model import User
from tests.test_role_flows import ACCOUNTS, PASSWORD, api, ok  # noqa: F401  (fixture)

DONOR = ACCOUNTS["donor"][0]
NEW_PASSWORD = "Relief#2026new"


def _capture(monkeypatch):
    """auth_router imported send_email directly, so patch it there."""
    sent = []
    monkeypatch.setattr(
        "api.v1.auth_router.send_email",
        lambda to, subject, body: sent.append({"to": to, "subject": subject, "body": body}) or True,
    )
    return sent


def _code(mail):
    return re.search(r"code is (\d{6})", mail["body"]).group(1)


def _reset(code, email=DONOR):
    return {"email": email, "code": code,
            "new_password": NEW_PASSWORD, "confirm_password": NEW_PASSWORD}


def test_forgot_password_answers_the_same_for_every_email(api, monkeypatch):
    client, t = api
    sent = _capture(monkeypatch)
    db = database.SessionLocal()
    try:
        db.query(User).filter(User.email == ACCOUNTS["csws"][0]).one().is_active = False
        db.commit()
    finally:
        db.close()
    replies = [client.post("/auth/forgot-password", json={"email": e})
               for e in (DONOR, "nobody@example.com", ACCOUNTS["csws"][0])]
    assert {r.status_code for r in replies} == {200}
    assert len({r.text for r in replies}) == 1            # identical answers
    assert [m["to"] for m in sent] == [DONOR]             # only the active account gets a code


def test_a_normal_reset_still_works(api, monkeypatch):
    client, t = api
    sent = _capture(monkeypatch)
    ok(client.post("/auth/forgot-password", json={"email": DONOR}))
    ok(client.post("/auth/reset-password", json=_reset(_code(sent[-1]))))
    ok(client.post("/token", data={"username": DONOR, "password": NEW_PASSWORD}))


def test_at_most_five_codes_an_hour(api, monkeypatch):
    client, t = api
    sent = _capture(monkeypatch)
    for _ in range(7):
        ok(client.post("/auth/forgot-password", json={"email": DONOR}))
    assert len(sent) == 5
    ok(client.post("/auth/reset-password", json=_reset(_code(sent[-1]))))   # newest still works


def test_new_codes_do_not_give_new_guesses(api, monkeypatch):
    client, t = api
    sent = _capture(monkeypatch)
    for _ in range(2):                                    # 2 codes x 5 wrong = 10 wrong guesses
        ok(client.post("/auth/forgot-password", json={"email": DONOR}))
        wrong = f"{(int(_code(sent[-1])) + 1) % 1_000_000:06d}"
        for _ in range(5):
            assert client.post("/auth/reset-password", json=_reset(wrong)).status_code == 400
    ok(client.post("/auth/forgot-password", json={"email": DONOR}))
    r = client.post("/auth/reset-password", json=_reset(_code(sent[-1])))
    assert r.status_code == 400                           # even the right code, this hour
    ok(client.post("/token", data={"username": DONOR, "password": PASSWORD}))   # password unchanged


def _login(client, password, user=DONOR):
    return client.post("/auth/login", json={"email": user, "password": password})


def test_five_wrong_passwords_make_that_login_wait(api):
    client, t = api
    for _ in range(5):
        assert _login(client, "wrong-pass1").status_code == 401
    r = _login(client, PASSWORD)                          # even the right password waits
    assert r.status_code == 429 and "Retry-After" in r.headers
    assert client.post("/token", data={"username": DONOR, "password": PASSWORD}).status_code == 429
    assert _login(client, PASSWORD, ACCOUNTS["csws"][0]).status_code == 200   # others unaffected
    for _ in range(5):                                    # unknown logins: same rule, no hint
        assert _login(client, "x", "nobody@example.com").status_code == 401
    assert _login(client, "x", "nobody@example.com").status_code == 429


def test_a_successful_login_resets_the_count(api):
    client, t = api
    for _ in range(4):
        assert _login(client, "wrong-pass1").status_code == 401
    assert _login(client, PASSWORD).status_code == 200
    for _ in range(4):
        assert _login(client, "wrong-pass1").status_code == 401
    assert _login(client, PASSWORD).status_code == 200


def test_the_wait_ends_after_15_minutes(api, monkeypatch):
    client, t = api
    clock = [1_000_000.0]
    monkeypatch.setattr("core.auth._now", lambda: clock[0])
    for _ in range(5):
        assert _login(client, "wrong-pass1").status_code == 401
    assert _login(client, PASSWORD).status_code == 429
    clock[0] += 15 * 60 + 1
    assert _login(client, PASSWORD).status_code == 200
