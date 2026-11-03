"""Android push notifications (core/push.py, GET /push/topic). No network:
FCM and Google's token endpoint are replaced by fakes."""
import jwt
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import rsa

from core import push
from core.notifications import notify_event
from tests.test_csws_drrmo_flow import _ask
from tests.test_logistics_needs import _delivery
from tests.test_pickup_days_and_runs import _activate_everyone
from tests.test_role_flows import api, ok  # noqa: F401  (fixture)

_KEY = rsa.generate_private_key(public_exponent=65537, key_size=2048)
FAKE = {
    "project_id": "nexaaid-test",
    "client_email": "push@nexaaid-test.iam.gserviceaccount.com",
    "private_key": _KEY.private_bytes(serialization.Encoding.PEM,
                                      serialization.PrivateFormat.PKCS8,
                                      serialization.NoEncryption()).decode(),
    "token_uri": "https://oauth2.example.test/token",
}


def _pushes_on(monkeypatch):
    """Pushes on with the fake account; returns the batches 'sent'."""
    batches = []
    monkeypatch.setattr(push, "credentials", lambda: FAKE)
    monkeypatch.setattr(push, "_submit", lambda fn, messages: batches.append(messages))
    return batches


def _topic(client, headers):
    return ok(client.get("/push/topic", headers=headers))["topic"]


def test_each_user_has_a_private_topic(api):
    client, t = api
    mine = ok(client.get("/push/topic", headers=t["drrmo"]))
    assert mine["enabled"] is False                     # no service account in tests
    assert mine["topic"].startswith("u_") and len(mine["topic"]) == 42
    assert _topic(client, t["drrmo"]) == mine["topic"]  # stable
    assert _topic(client, t["csws"]) != mine["topic"]
    assert client.get("/push/topic").status_code == 401


def test_a_notification_is_pushed_after_the_commit(api, monkeypatch):
    client, t = api
    _activate_everyone()
    did = _delivery(client, t)["delivery_id"]
    batches = _pushes_on(monkeypatch)
    rid = _ask(client, t, did)["request_id"]            # CSWS asks DRRMO

    sent = [m for b in batches for m in b]
    to_drrmo = [m for m in sent if m["topic"] == _topic(client, t["drrmo"])]
    assert len(to_drrmo) == 1
    m = to_drrmo[0]
    assert m["notification"]["title"] == "Logistics requested"
    assert m["data"]["event"] == "logistics_requested"
    assert m["data"]["entity_type"] == "logistics_request"
    assert m["data"]["entity_id"] == str(rid)
    # The app marks that notice read when the push is tapped.
    inbox = ok(client.get("/notifications/", headers=t["drrmo"]))["items"]
    assert m["data"]["notification_id"] == str(inbox[0]["notification_id"])
    assert all(isinstance(v, str) for v in m["data"].values())


def test_nothing_is_pushed_for_a_save_that_was_rolled_back(api, monkeypatch):
    from core import database
    batches = _pushes_on(monkeypatch)
    db = database.SessionLocal()
    try:
        notify_event(db, 1, "logistics_requested", "logistics_request", 99, title="x")
        db.rollback()
        notify_event(db, 1, "logistics_requested", "logistics_request", 100, title="y")
        db.commit()
    finally:
        db.close()
    assert [m["data"]["entity_id"] for b in batches for m in b] == ["100"]


def test_a_broken_push_never_breaks_the_save(api, monkeypatch):
    client, t = api
    _activate_everyone()
    did = _delivery(client, t)["delivery_id"]
    monkeypatch.setattr(push, "credentials", lambda: FAKE)
    monkeypatch.setattr(push, "_submit", lambda *a: 1 / 0)
    _ask(client, t, did)                                # still 201
    assert [r["delivery_id"] for r in ok(client.get("/logistics/requests", headers=t["csws"]))] == [did]


class _Resp:
    def __init__(self, status, body=None):
        self.status_code, self._body = status, body or {}

    def json(self):
        return self._body

    def raise_for_status(self):
        if self.status_code >= 300:
            raise RuntimeError(self.status_code)


def test_sending_signs_in_with_the_service_account_and_calls_fcm(monkeypatch):
    calls = []

    def fake_post(url, **kw):
        calls.append((url, kw))
        if url == FAKE["token_uri"]:
            return _Resp(200, {"access_token": "tok-1", "expires_in": 3600})
        return _Resp(200)

    monkeypatch.setattr(push, "credentials", lambda: FAKE)
    monkeypatch.setattr(push.httpx, "post", fake_post)
    monkeypatch.setattr(push, "_token", None)
    msg = {"topic": "u_x", "notification": {"title": "t", "body": "b"}, "data": {"event": "e"}}
    push._send_all([msg, msg])

    token_calls = [kw for url, kw in calls if url == FAKE["token_uri"]]
    assert len(token_calls) == 1                        # the token is reused
    claims = jwt.decode(token_calls[0]["data"]["assertion"], _KEY.public_key(),
                        algorithms=["RS256"], audience=FAKE["token_uri"])
    assert claims["iss"] == FAKE["client_email"]
    assert claims["scope"].endswith("/firebase.messaging")
    sends = [(url, kw) for url, kw in calls if url != FAKE["token_uri"]]
    assert len(sends) == 2
    url, kw = sends[0]
    assert url == "https://fcm.googleapis.com/v1/projects/nexaaid-test/messages:send"
    assert kw["headers"]["Authorization"] == "Bearer tok-1"
    assert kw["json"] == {"message": msg}


def test_a_failing_fcm_call_is_logged_not_raised(monkeypatch):
    monkeypatch.setattr(push, "credentials", lambda: FAKE)
    monkeypatch.setattr(push, "_token", None)
    monkeypatch.setattr(push.httpx, "post", lambda *a, **k: 1 / 0)
    push._send_all([{"topic": "u_x", "data": {}}])      # no exception


def test_credentials_come_from_the_environment(monkeypatch, tmp_path):
    import json
    monkeypatch.delenv("FIREBASE_CREDENTIALS_JSON", raising=False)
    monkeypatch.delenv("FIREBASE_CREDENTIALS_FILE", raising=False)
    assert push._load_credentials() is None
    monkeypatch.setenv("FIREBASE_CREDENTIALS_JSON", "not json")
    assert push._load_credentials() is None
    monkeypatch.setenv("FIREBASE_CREDENTIALS_JSON", json.dumps(FAKE))
    assert push._load_credentials()["project_id"] == "nexaaid-test"
    monkeypatch.delenv("FIREBASE_CREDENTIALS_JSON")
    key_file = tmp_path / "firebase-service-account.json"
    key_file.write_text(json.dumps(FAKE), encoding="utf-8")
    monkeypatch.setenv("FIREBASE_CREDENTIALS_FILE", str(key_file))
    assert push._load_credentials()["client_email"] == FAKE["client_email"]
