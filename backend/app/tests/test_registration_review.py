"""Oct 11 notes (Jenises): the Administrator reviews new registrations of
individual donors as well as organizations (review only, the accounts are
active either way), and the dashboard counts both."""
from tests.test_role_flows import api, ok  # noqa: F401  (fixture)


def _donor_id(client, t):
    rows = ok(client.get("/admin/users", params={"role": "Individual Donor"}, headers=t["admin"]))
    return rows[0]["user_id"], rows[0]


def test_admin_reviews_individual_donor_registrations(api):
    client, t = api
    donor_id, row = _donor_id(client, t)
    assert row["reviewed_at"] is None  # new donors start as Not Reviewed
    before = ok(client.get("/dashboard/admin", headers=t["admin"]))["pending_registrations"]

    done = ok(client.patch(f"/admin/users/{donor_id}/review", json={"reviewed": True}, headers=t["admin"]))
    assert done["reviewed_at"] is not None
    assert _donor_id(client, t)[1]["reviewed_at"] is not None
    assert ok(client.get("/dashboard/admin", headers=t["admin"]))["pending_registrations"] == before - 1

    # Undo, and the account stays active the whole time
    ok(client.patch(f"/admin/users/{donor_id}/review", json={"reviewed": False}, headers=t["admin"]))
    again = _donor_id(client, t)[1]
    assert again["reviewed_at"] is None and again["is_active"]

    # Only donors are reviewed here; only the Administrator may do it
    staff = ok(client.get("/admin/users", params={"role": "CMO Representative"}, headers=t["admin"]))[0]
    ok(client.patch(f"/admin/users/{staff['user_id']}/review", json={"reviewed": True}, headers=t["admin"]), 409)
    ok(client.patch(f"/admin/users/{donor_id}/review", json={"reviewed": "yes"}, headers=t["admin"]), 422)
    ok(client.patch(f"/admin/users/{donor_id}/review", json={"reviewed": True}, headers=t["csws"]), 403)


def test_organization_rows_carry_their_account_for_view_account(api):
    """problema_napud 1.1: organization registrations have "View account"
    too, so each row names the organization's own account."""
    from tests.reg_helpers import org_payload
    client, t = api
    org = ok(client.post("/auth/register/organization",
                         json=org_payload(client, "ops@relief.ph")), 201)
    rows = ok(client.get("/admin/organizations", headers=t["admin"]))
    row = next(r for r in rows if r["organization_id"] == org["organization_id"])
    assert row["user_id"]
    account = ok(client.get(f"/admin/users/{row['user_id']}", headers=t["admin"]))
    assert account["email"] == "ops@relief.ph"
