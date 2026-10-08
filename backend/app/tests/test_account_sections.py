"""I2 (Module 1.2): the admin account list has Active and Deactivated sections."""
from tests.test_role_flows import api, ok  # noqa: F401  (fixture)


def _users(client, t, **params):
    return ok(client.get("/admin/users", params=params, headers=t["admin"]))


def _csws_id(client, t):
    everyone = _users(client, t)
    return next(u for u in everyone if u["email"] == "csws.test@example.com")["user_id"]


def test_active_and_deactivated_sections(api):
    client, t = api
    everyone = _users(client, t)
    csws = next(u for u in everyone if u["email"] == "csws.test@example.com")["user_id"]

    ok(client.patch(f"/admin/users/{csws}", headers=t["admin"], json={"is_active": False, "deactivation_reason": "Test reason"}))
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


def test_deactivation_requires_a_reason(api):
    client, t = api
    csws = _csws_id(client, t)

    for body in ({"is_active": False},
                 {"is_active": False, "deactivation_reason": ""},
                 {"is_active": False, "deactivation_reason": "   "}):
        ok(client.patch(f"/admin/users/{csws}", headers=t["admin"], json=body), 422)

    # The refused requests must not have deactivated the account.
    assert csws in [u["user_id"] for u in _users(client, t, active="true")]


def test_deactivation_reason_is_saved_and_cleared(api):
    client, t = api
    csws = _csws_id(client, t)

    r = ok(client.patch(f"/admin/users/{csws}", headers=t["admin"],
                        json={"is_active": False, "deactivation_reason": "  Left the organisation  "}))
    assert r["deactivation_reason"] == "Left the organisation"
    assert r["deactivated_at"] is not None

    row = next(u for u in _users(client, t, active="false") if u["user_id"] == csws)
    assert row["deactivation_reason"] == "Left the organisation"

    r = ok(client.patch(f"/admin/users/{csws}", headers=t["admin"], json={"is_active": True}))
    assert r["deactivation_reason"] is None
    assert r["deactivated_at"] is None


def test_detail_shows_deactivation_reason(api):
    client, t = api
    csws = _csws_id(client, t)

    d = ok(client.get(f"/admin/users/{csws}", headers=t["admin"]))
    assert d["deactivation_reason"] is None and d["deactivated_at"] is None

    ok(client.patch(f"/admin/users/{csws}", headers=t["admin"],
                    json={"is_active": False, "deactivation_reason": "Left the organisation"}))
    d = ok(client.get(f"/admin/users/{csws}", headers=t["admin"]))
    assert d["deactivation_reason"] == "Left the organisation"
    assert d["deactivated_at"] is not None

def _csws_id(client, t):
    everyone = _users(client, t)
    return next(u for u in everyone if u["email"] == "csws.test@example.com")["user_id"]


def test_deactivation_requires_a_reason(api):
    client, t = api
    csws = _csws_id(client, t)
    for body in ({"is_active": False},
                 {"is_active": False, "deactivation_reason": ""},
                 {"is_active": False, "deactivation_reason": "   "}):
        ok(client.patch(f"/admin/users/{csws}", headers=t["admin"], json=body), 422)
    assert csws in [u["user_id"] for u in _users(client, t, active="true")]


def test_deactivation_reason_is_saved_and_cleared(api):
    client, t = api
    csws = _csws_id(client, t)
    r = ok(client.patch(f"/admin/users/{csws}", headers=t["admin"],
                        json={"is_active": False, "deactivation_reason": "  Left the organisation  "}))
    assert r["deactivation_reason"] == "Left the organisation"
    assert r["deactivated_at"] is not None
    row = next(u for u in _users(client, t, active="false") if u["user_id"] == csws)
    assert row["deactivation_reason"] == "Left the organisation"
    r = ok(client.patch(f"/admin/users/{csws}", headers=t["admin"], json={"is_active": True}))
    assert r["deactivation_reason"] is None
    assert r["deactivated_at"] is None


def test_detail_shows_deactivation_reason(api):
    client, t = api
    csws = _csws_id(client, t)
    d = ok(client.get(f"/admin/users/{csws}", headers=t["admin"]))
    assert d["deactivation_reason"] is None and d["deactivated_at"] is None
    ok(client.patch(f"/admin/users/{csws}", headers=t["admin"],
                    json={"is_active": False, "deactivation_reason": "Left the organisation"}))
    d = ok(client.get(f"/admin/users/{csws}", headers=t["admin"]))
    assert d["deactivation_reason"] == "Left the organisation"
    assert d["deactivated_at"] is not None
