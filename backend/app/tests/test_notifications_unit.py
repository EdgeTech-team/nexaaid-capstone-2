"""No database needed. Run from backend/app:  pytest tests/test_notifications_unit.py"""
import core.email as mail
from core.notifications import render_event


def test_render_fills_template():
    title, body = render_event("donation_received", batch_no=12)
    assert title == "Donation received"
    assert "#12" in body


def test_render_missing_ctx_does_not_crash():
    _, body = render_event("report_rejected", title="Flood in Subangdaku")
    assert "Flood in Subangdaku" in body


def test_render_unknown_event_falls_back_to_key():
    assert render_event("nope")[0] == "nope"


def test_send_email_unconfigured_returns_false(monkeypatch):
    for k in ("BREVO_API_KEY", "SMTP_USER", "SMTP_PASSWORD", "SMTP_APP_PASSWORD"):
        monkeypatch.delenv(k, raising=False)
    assert mail.send_email("a@b.com", "Hi", "body") is False


def test_send_email_success_strips_app_password_spaces(monkeypatch):
    monkeypatch.delenv("BREVO_API_KEY", raising=False)
    monkeypatch.setenv("SMTP_USER", "u@gmail.com")
    monkeypatch.setenv("SMTP_PASSWORD", "abcd efgh ijkl mnop")
    seen = {}

    class FakeSMTP:
        def __init__(self, *a, **k): pass
        def __enter__(self): return self
        def __exit__(self, *a): return False
        def starttls(self): pass
        def login(self, u, p): seen["pw"] = p
        def send_message(self, m): seen["to"] = m["To"]

    monkeypatch.setattr(mail.smtplib, "SMTP", FakeSMTP)
    assert mail.send_email("x@y.com", "S", "B") is True
    assert seen == {"pw": "abcdefghijklmnop", "to": "x@y.com"}


def test_send_email_failure_returns_false(monkeypatch):
    monkeypatch.delenv("BREVO_API_KEY", raising=False)
    monkeypatch.setenv("SMTP_USER", "u@gmail.com")
    monkeypatch.setenv("SMTP_PASSWORD", "pw")

    def boom(*a, **k):
        raise OSError("network down")

    monkeypatch.setattr(mail.smtplib, "SMTP", boom)
    assert mail.send_email("x@y.com", "S", "B") is False


def test_send_email_uses_brevo_when_key_set(monkeypatch):
    monkeypatch.setenv("BREVO_API_KEY", "xkeysib-test")
    monkeypatch.setenv("EMAIL_FROM", "team@example.com")
    seen = {}

    class FakeResponse:
        def raise_for_status(self): pass

    def fake_post(url, json=None, headers=None, timeout=None):
        seen.update(url=url, json=json, key=headers["api-key"])
        return FakeResponse()

    monkeypatch.setattr(mail.httpx, "post", fake_post)
    assert mail.send_email("x@y.com", "S", "B") is True
    assert seen["url"] == mail.BREVO_URL
    assert seen["key"] == "xkeysib-test"
    assert seen["json"]["to"] == [{"email": "x@y.com"}]
    assert seen["json"]["sender"]["email"] == "team@example.com"


def test_send_email_brevo_failure_returns_false(monkeypatch):
    monkeypatch.setenv("BREVO_API_KEY", "xkeysib-test")
    monkeypatch.setenv("EMAIL_FROM", "team@example.com")

    def boom(*a, **k):
        raise OSError("network down")

    monkeypatch.setattr(mail.httpx, "post", boom)
    assert mail.send_email("x@y.com", "S", "B") is False