"""Organization registrations are active immediately and tracked separately
from administrative review.
"""
from tests.reg_helpers import STRONG_PASSWORD, org_payload
from tests.test_role_flows import api, ok  # noqa: F401


def test_organization_review_can_be_toggled(api):
    client, t = api
    org = ok(
        client.post(
            "/auth/register/organization",
            json=org_payload(client, "review-test@relief.ph"),
        ),
        201,
    )
    oid = org["organization_id"]

    # Registration is active without waiting for an admin review.
    login = client.post(
        "/token",
        data={
            "username": "review-test@relief.ph",
            "password": STRONG_PASSWORD,
        },
    )
    assert login.status_code == 200

    not_reviewed = ok(
        client.get(
            "/admin/organizations",
            params={"reviewed": False},
            headers=t["admin"],
        )
    )
    row = next(o for o in not_reviewed if o["organization_id"] == oid)
    assert row["reviewed_at"] is None

    reviewed = ok(
        client.patch(
            f"/admin/organizations/{oid}/review",
            headers=t["admin"],
            json={"reviewed": True},
        )
    )
    assert reviewed["reviewed_at"] is not None
    assert reviewed["reviewed_by_user_id"] is not None

    reviewed_rows = ok(
        client.get(
            "/admin/organizations",
            params={"reviewed": True},
            headers=t["admin"],
        )
    )
    assert any(o["organization_id"] == oid for o in reviewed_rows)

    # Marking it not reviewed clears review metadata without deactivating it.
    reset = ok(
        client.patch(
            f"/admin/organizations/{oid}/review",
            headers=t["admin"],
            json={"reviewed": False},
        )
    )
    assert reset["reviewed_at"] is None
    assert reset["reviewed_by_user_id"] is None
    assert reset["status"] == "Approved"

    assert client.patch(
        f"/admin/organizations/{oid}/review",
        headers=t["csws"],
        json={"reviewed": True},
    ).status_code == 403


def test_organization_review_rejects_invalid_payload_and_unknown_id(api):
    client, t = api

    invalid = client.patch(
        "/admin/organizations/1/review",
        headers=t["admin"],
        json={"reviewed": "yes"},
    )
    assert invalid.status_code == 422

    missing = client.patch(
        "/admin/organizations/999999/review",
        headers=t["admin"],
        json={"reviewed": True},
    )
    assert missing.status_code == 404
