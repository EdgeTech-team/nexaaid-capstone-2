"""F-21: the client address comes from the trusted end of X-Forwarded-For,
only in production; a forged left-hand entry is never used."""
from fastapi import FastAPI, Request
from fastapi.testclient import TestClient

import core.client_ip as client_ip
import core.database as database
from core.client_ip import ClientIPMiddleware, client_from_forwarded
from core.config import settings
from models.audit_log_model import AuditLog
from tests.test_change_password import NEW_PASSWORD
from tests.test_role_flows import PASSWORD, api, ok  # noqa: F401  (fixture)

CLIENT = "203.0.113.7"        # documentation-only addresses (RFC 5737)
FORGED = "1.2.3.4"
CLOUDFLARE = "162.158.1.1"


def test_rightmost_entry_by_default():
    assert client_from_forwarded(CLIENT, 1) == CLIENT
    assert client_from_forwarded(f"{FORGED}, {CLIENT}", 1) == CLIENT
    assert client_from_forwarded(f"{FORGED},{CLIENT}", 1) == CLIENT


def test_two_hops_skips_the_cloudflare_entry():
    assert client_from_forwarded(f"{FORGED}, {CLIENT}, {CLOUDFLARE}", 2) == CLIENT
    assert client_from_forwarded(f"{CLIENT}, {CLOUDFLARE}", 2) == CLIENT


def test_unusable_values_keep_the_direct_address():
    assert client_from_forwarded("", 1) is None
    assert client_from_forwarded("not-an-ip", 1) is None
    assert client_from_forwarded(f"{CLIENT}:443", 1) is None
    assert client_from_forwarded(CLIENT, 2) is None        # fewer entries than hops
    assert client_from_forwarded(CLIENT, 0) is None
    assert client_from_forwarded("2001:db8::1", 1) == "2001:db8::1"


def _probe():
    app = FastAPI()

    @app.get("/who")
    def who(request: Request):
        return {"ip": request.client.host, "scheme": request.url.scheme}

    app.add_middleware(ClientIPMiddleware)
    return TestClient(app)


def test_middleware_only_in_production(monkeypatch):
    client = _probe()
    headers = {"X-Forwarded-For": f"{FORGED}, {CLIENT}", "X-Forwarded-Proto": "https"}
    monkeypatch.setattr(settings, "APP_ENV", "development")
    assert client.get("/who", headers=headers).json() == {"ip": "testclient", "scheme": "http"}
    monkeypatch.setattr(settings, "APP_ENV", "production")
    assert client.get("/who", headers=headers).json() == {"ip": CLIENT, "scheme": "https"}
    assert client.get("/who").json()["ip"] == "testclient"            # no header
    monkeypatch.setattr(client_ip, "TRUSTED_PROXY_HOPS", 2)
    three = {"X-Forwarded-For": f"{FORGED}, {CLIENT}, {CLOUDFLARE}"}
    assert client.get("/who", headers=three).json()["ip"] == CLIENT


def test_audit_log_records_the_client_address(api, monkeypatch):
    client, t = api
    monkeypatch.setattr(settings, "APP_ENV", "production")
    ok(client.post(
        "/auth/change-password",
        headers={**t["donor"], "X-Forwarded-For": f"{FORGED}, {CLIENT}"},
        json={"current_password": PASSWORD, "new_password": NEW_PASSWORD,
              "confirm_password": NEW_PASSWORD},
    ))
    db = database.SessionLocal()
    try:
        row = (db.query(AuditLog).filter(AuditLog.action == "CHANGE PASSWORD")
               .order_by(AuditLog.log_id.desc()).first())
        assert row.ip_address == CLIENT
    finally:
        db.close()
