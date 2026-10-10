"""
Forgot password (login screen, Ivan): POST /auth/forgot-password emails a new
temporary password and flags must_change_password, reusing the UC-A1 flow.
"""
import re

import core.database as database
from models.user_rbac_model import User
from tests.test_role_flows import PASSWORD, api, ok  # noqa: F401  (fixture)

URL = "/auth/forgot-password"
DONOR = "donor.test@example.com"


def _login(client, email, password):
    return client.post("/auth/login", json={"email": email, "password": password})


def test_forgot_password_emails_a_temporary_password(api, sent_emails, monkeypatch):
    client, _ = api
    monkeypatch.setattr("core.email.email_configured", lambda: True)

    reply = ok(client.post(URL, json={"email": "  Donor.Test@Example.com "}))
    assert "temporary password" in reply["detail"]
    assert len(sent_emails) == 1 and sent_emails[0]["to"] == DONOR
    temp = re.search(r"Temporary password: (\S+)", sent_emails[0]["body"]).group(1)

    # Old password stops working; the temporary one signs in and must be changed.
    assert _login(client, DONOR, PASSWORD).status_code == 401
    assert ok(_login(client, DONOR, temp))["user"]["must_change_password"] is True


def test_unknown_or_deactivated_email_gets_same_reply_and_no_email(api, sent_emails, monkeypatch):
    client, _ = api
    monkeypatch.setattr("core.email.email_configured", lambda: True)
    known = ok(client.post(URL, json={"email": DONOR}))["detail"]
    sent_emails.clear()

    assert ok(client.post(URL, json={"email": "nobody@example.com"}))["detail"] == known

    db = database.SessionLocal()
    try:
        db.query(User).filter(User.email == "cmo.test@example.com").one().is_active = False
        db.commit()
    finally:
        db.close()
    assert ok(client.post(URL, json={"email": "cmo.test@example.com"}))["detail"] == known
    assert sent_emails == []
    assert _login(client, "cmo.test@example.com", PASSWORD).status_code == 403


def test_forgot_password_needs_email_set_up(api, monkeypatch):
    client, _ = api
    monkeypatch.setattr("core.email.email_configured", lambda: False)
    assert client.post(URL, json={"email": DONOR}).status_code == 503
    # Nothing changed: the current password still works.
    ok(_login(client, DONOR, PASSWORD))
