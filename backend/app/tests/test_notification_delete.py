"""Delete read notifications: DELETE /notifications/read and /notifications/{id}.

Only the user's own, already-read notifications can be deleted. Unread ones
stay, and nobody can delete another user's notifications.
"""
import core.database as database
from models.notification import Notification
from models.user_rbac_model import User
from tests.test_role_flows import ACCOUNTS, api, ok  # noqa: F401  (fixture)


def _user_id(key):
    db = database.SessionLocal()
    try:
        return db.query(User).filter(User.email == ACCOUNTS[key][0]).one().user_id
    finally:
        db.close()


def _add(key, title, is_read):
    db = database.SessionLocal()
    try:
        n = Notification(user_id=_user_id(key), type="test_event", title=title,
                         message="body", is_read=is_read)
        db.add(n)
        db.commit()
        return n.notification_id
    finally:
        db.close()


def _titles(client, headers):
    return sorted(n["title"] for n in ok(client.get("/notifications/", headers=headers))["items"])


def test_delete_read_keeps_unread_and_other_users(api):
    client, t = api
    _add("donor", "read one", True)
    _add("donor", "read two", True)
    _add("donor", "unread one", False)
    _add("csws", "csws read", True)

    body = ok(client.delete("/notifications/read", headers=t["donor"]))
    assert body["deleted"] == 2
    assert body["unread_count"] == 1
    assert _titles(client, t["donor"]) == ["unread one"]
    # Another user's read notification is untouched.
    assert _titles(client, t["csws"]) == ["csws read"]
    # Nothing left to delete: still fine.
    assert ok(client.delete("/notifications/read", headers=t["donor"]))["deleted"] == 0


def test_delete_one_read_notification(api):
    client, t = api
    read_id = _add("donor", "read", True)
    _add("donor", "unread", False)

    body = ok(client.delete(f"/notifications/{read_id}", headers=t["donor"]))
    assert body["unread_count"] == 1
    assert _titles(client, t["donor"]) == ["unread"]
    assert client.delete(f"/notifications/{read_id}", headers=t["donor"]).status_code == 404


def test_cannot_delete_unread_or_someone_elses(api):
    client, t = api
    unread_id = _add("donor", "unread", False)
    other_read_id = _add("csws", "csws read", True)

    r = client.delete(f"/notifications/{unread_id}", headers=t["donor"])
    assert r.status_code == 409
    assert client.delete(f"/notifications/{other_read_id}", headers=t["donor"]).status_code == 404
    assert _titles(client, t["donor"]) == ["unread"]
    assert _titles(client, t["csws"]) == ["csws read"]


def test_delete_needs_login(api):
    client, _ = api
    assert client.delete("/notifications/read").status_code == 401