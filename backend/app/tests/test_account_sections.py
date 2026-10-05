"""I2 (Module 1.2): the admin account list has Active and Deactivated sections."""
from tests.test_role_flows import api, ok  # noqa: F401  (fixture)


def _users(client, t, **params):
    return ok(client.get("/admin/users", params=params, headers=t["admin"]))


def test_active_and_deactivated_sections(api):
    client, t = api
    everyone = _users(client, t)
    csws = next(u for u in everyone if u["email"] == "csws.test@example.com")["user_id"]

    ok(client.patch(f"/admin/users/{csws}", headers=t["admin"], json={"is_active": False}))
    active = _users(client, t, active="true")
    off = _users(client, t, active="false")
    assert all(u["is_active"] for u in active) and csws not in [u["user_id"] for u in active]
    assert not any(u["is_active"] for u in off) and csws in [u["user_id"] for u in off]
    # No filter still returns everyone (older screens keep working).
    assert len(_users(client, t)) == len(active) + len(off)
    # The filter works together with role and search.
    assert [u["user_id"] for u in _users(client, t, active="false", q="csws.test")] == [csws]

    ok(client.patch(f"/admin/users/{csws}", headers=t["admin"], json={"is_active": True}))
    assert csws not in [u["user_id"] for u in _users(client, t, active="false")]
    assert client.get("/admin/users", params={"active": "false"},
                      headers=t["csws"]).status_code == 403