"""Phase 4: live updates over WebSocket (core/realtime.py, GET /ws) and the
delivery timeline (Table 37) from GET /deliveries/{id}/history."""
import pytest
from starlette.websockets import WebSocketDisconnect

from core import realtime
from core.notifications import notify_event
from tests.test_csws_drrmo_flow import _ask
from tests.test_logistics_needs import _delivery
from tests.test_pickup_days_and_runs import _activate_everyone
from tests.test_role_flows import accept_body, api, ok  # noqa: F401  (fixture)


def _token(headers):
    return headers["Authorization"].split()[1]


def test_a_new_notification_reaches_the_open_app_at_once(api):
    client, t = api
    _activate_everyone()          # notices go to active accounts only
    did = _delivery(client, t)["delivery_id"]
    with client.websocket_connect(f"/ws?token={_token(t['drrmo'])}") as ws:
        hello = ws.receive_json()
        assert hello["type"] == "hello" and isinstance(hello["unread_count"], int)
        ws.send_text("ping")
        assert ws.receive_text() == "pong"

        rid = _ask(client, t, did)["request_id"]        # CSWS asks DRRMO
        msg = ws.receive_json()
        assert msg == {"type": "notification", "event": "logistics_requested",
                       "entity_type": "logistics_request", "entity_id": rid,
                       "unread_count": hello["unread_count"] + 1}
    assert realtime.connection_count() == 0             # closed sockets are forgotten


def test_bad_tokens_are_refused(api):
    client, _ = api
    with pytest.raises(WebSocketDisconnect):
        with client.websocket_connect("/ws?token=not-a-token") as ws:
            ws.receive_json()
    with pytest.raises(WebSocketDisconnect):
        with client.websocket_connect("/ws") as ws:
            ws.receive_json()


def test_nothing_is_pushed_for_a_save_that_was_rolled_back(api):
    """Rule: a push follows the commit; a rollback drops it."""
    from core import database
    client, t = api
    with client.websocket_connect(f"/ws?token={_token(t['drrmo'])}") as ws:
        ws.receive_json()                                   # hello
        db = database.SessionLocal()
        try:
            drrmo_id = next(uid for uid in list(realtime._connections))
            notify_event(db, drrmo_id, "logistics_requested", "logistics_request", 99, title="x")
            db.rollback()
            notify_event(db, drrmo_id, "logistics_requested", "logistics_request", 100, title="y")
            db.commit()
        finally:
            db.close()
        assert ws.receive_json()["entity_id"] == 100        # 99 never arrives


def test_a_broken_push_never_breaks_the_save(api, monkeypatch):
    client, t = api
    did = _delivery(client, t)["delivery_id"]
    monkeypatch.setattr(realtime, "is_online", lambda uid: True)
    monkeypatch.setattr(realtime, "send_to_user", lambda *a, **k: 1 / 0)
    # The push fails after the commit: logged, and the user still gets 201.
    _ask(client, t, did)
    rows = ok(client.get("/logistics/requests", headers=t["csws"]))
    assert [r["delivery_id"] for r in rows] == [did]


def test_timeline_in_staff_words(api):
    client, t = api
    did = _delivery(client, t)["delivery_id"]
    rid = _ask(client, t, did)["request_id"]

    def steps():
        return {s["key"]: s for s in ok(client.get(f"/deliveries/{did}/history",
                                                   headers=t["csws"]))["timeline"]}

    s = steps()
    assert [x["label"] for x in s.values()] == [
        "Being packed", "Truck assigned", "On the way", "Arrived", "Received by barangay"]
    assert s["packed"]["done"] and s["packed"]["by"]
    assert not s["truck"]["done"] and s["truck"]["detail"] == "Waiting for DRRMO to accept"

    ok(client.patch(f"/drrmo/requests/{rid}/accept", headers=t["drrmo"],
                    json=accept_body(vehicle="Truck 2", driver="Juan")))
    ok(client.post(f"/drrmo/requests/{rid}/picked-up", headers=t["drrmo"]))
    s = steps()
    assert s["truck"]["done"] and "DRRMO arriving" in s["truck"]["detail"]
    assert "Truck 2" in s["truck"]["detail"] and "Driver: Juan" in s["truck"]["detail"]
    assert s["on_the_way"]["done"] and s["on_the_way"]["at"] and s["on_the_way"]["by"]
    assert not s["arrived"]["done"] and s["arrived"]["at"] is None
