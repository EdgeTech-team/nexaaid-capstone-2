"""Testing (Oct 23): DRRMO and CSWS Main Office share logistics
notifications. The whole of both teams hears what happened, not only the
person who made the request; whoever did the action is not told."""
from core import database
from core.auth import hash_password
from models.user_rbac_model import User
from tests.test_logistics_needs import _delivery
from tests.test_pickup_days_and_runs import _activate_everyone
from tests.test_role_flows import PASSWORD, ROLES, api, ok  # noqa: F401  (fixture)


def _add_user(client, key, role_name):
    db = database.SessionLocal()
    try:
        role_id = next(i for i, n in ROLES.items() if n == role_name)
        db.add(User(first_name=key, last_name="Test", contact_number="09170000000",
                    email=f"{key}@test.local", password_hash=hash_password(PASSWORD),
                    role_id=role_id))
        db.commit()
    finally:
        db.close()
    r = client.post("/token", data={"username": f"{key}@test.local", "password": PASSWORD})
    return {"Authorization": f"Bearer {r.json()['access_token']}"}


def _events(client, headers):
    return [n["type"] for n in ok(client.get("/notifications/", headers=headers))["items"]]


def test_both_teams_hear_every_logistics_step(api):
    client, t = api
    csws2 = _add_user(client, "csws2", "CSWS Main Office")
    drrmo2 = _add_user(client, "drrmo2", "DRRMO Logistics Support")
    _activate_everyone()
    did = _delivery(client, t)["delivery_id"]

    req = ok(client.post("/logistics/requests", headers=t["csws"],
                         json={"delivery_id": did, "trucks": 1}), 201)
    # Asked: both DRRMO staff and the other CSWS staff; not the requester.
    assert "logistics_requested" in _events(client, t["drrmo"])
    assert "logistics_requested" in _events(client, drrmo2)
    assert "logistics_requested" in _events(client, csws2)
    assert "logistics_requested" not in _events(client, t["csws"])

    ok(client.patch(f"/drrmo/requests/{req['request_id']}/accept", headers=t["drrmo"], json={}))
    # Accepted: the requester, the other CSWS staff and the other DRRMO staff.
    assert "logistics_accepted" in _events(client, t["csws"])
    assert "logistics_accepted" in _events(client, csws2)
    assert "logistics_accepted" in _events(client, drrmo2)
    assert "logistics_accepted" not in _events(client, t["drrmo"])

    ok(client.patch(f"/drrmo/requests/{req['request_id']}/complete", headers=drrmo2,
                    json={"summary": "Truck 2, one trip"}))
    assert "logistics_completed" in _events(client, csws2)
    assert "logistics_completed" in _events(client, t["drrmo"])
    assert "logistics_completed" not in _events(client, drrmo2)
