"""
I3 (Module 1.2): rejected organization registrations keep their reason in
organizations.rejection_reason, and the admin's Rejected section shows it.
Dave's login message (D6) reads the same column.

Needs Castillo's schema PR (organizations.rejection_reason).
"""
import core.database as database
from models.organization_model import Organization
from tests.reg_helpers import org_payload
from tests.test_role_flows import api, ok  # noqa: F401  (fixture)

REASON = "SEC certificate is expired"


def _column(oid):
    db = database.SessionLocal()
    try:
        return db.get(Organization, oid).rejection_reason
    finally:
        db.close()


def _rejected(client, t):
    return ok(client.get("/admin/organizations", params={"status": "Rejected"}, headers=t["admin"]))


def test_rejected_section_shows_the_saved_reason(api):
    client, t = api
    org = ok(client.post("/auth/register/organization", json=org_payload(client, "rej@relief.ph")), 201)
    oid = org["organization_id"]
    url = f"/admin/organizations/{oid}/decision"

    ok(client.post(url, headers=t["admin"], json={"decision": "Rejected", "reason": REASON}))
    assert _column(oid) == REASON
    row = next(o for o in _rejected(client, t) if o["organization_id"] == oid)
    assert row["rejection_reason"] == REASON
    assert row["decision_reason"] == REASON
    assert row["decided_at"] is not None

    # Holding or approving it later clears the rejection reason.
    ok(client.post(url, headers=t["admin"], json={"decision": "Pending", "reason": "Waiting for new SEC copy"}))
    assert _column(oid) is None
    ok(client.post(url, headers=t["admin"], json={"decision": "Approved"}))
    assert _column(oid) is None
    assert oid not in [o["organization_id"] for o in _rejected(client, t)]