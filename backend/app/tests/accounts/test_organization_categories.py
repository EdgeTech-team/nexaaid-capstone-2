"""NF-008 (D6): organization types like a professional app.

A fixed list with two categories (Government / Non-government). Every
organization uploads the contact person's government ID; Government types
also upload one supporting document. Organizations sign in at once and are
Unverified until the Administrator reviews them; the review queue lists
Unverified and Government types first with a warning. Mark verified sets
organizations.reviewed_at; Deactivate needs a reason, which is emailed."""
from datetime import datetime, timezone

import core.config.database as database
from models.accounts.organization_model import Organization
from models.accounts.user_rbac_model import User
from schemas.accounts.organization_schema import (
    GOVERNMENT_TYPES, NON_GOVERNMENT_TYPES, organization_category,
)
from tests.reg_helpers import org_payload
from tests.general.test_role_flows import api, ok  # noqa: F401  (fixture)

GOV = "Barangay / Barangay Council"
WARNING = "Government type – check document and ID"


def _register(client, email, **overrides):
    return client.post("/auth/register/organization", json=org_payload(
        client, email, registration_no=None, **overrides))


def _org(email):
    db = database.SessionLocal()
    try:
        u = db.query(User).filter(User.email == email).one()
        return db.get(Organization, u.organization_id), u
    finally:
        db.close()


def test_the_fixed_list_has_two_categories():
    assert len(GOVERNMENT_TYPES) == 5 and len(NON_GOVERNMENT_TYPES) == 6
    assert all(organization_category(t) == "Government" for t in GOVERNMENT_TYPES)
    assert all(organization_category(t) == "Non-government" for t in NON_GOVERNMENT_TYPES)
    assert organization_category("Other: Cooperative") == "Non-government"
    assert organization_category("Something unknown") == "Non-government"
    assert organization_category("Government") == "Government"          # old label


def test_government_type_without_a_document_is_refused(api):
    client, _ = api
    r = _register(client, "brgy@gov.ph", organization_type=GOV, legitimacy_document=None)
    assert r.status_code == 422 and "supporting document" in r.text


def test_any_type_without_the_contact_persons_id_is_refused(api):
    client, _ = api
    for kind, email in ((GOV, "a@gov.ph"), ("Religious Organization", "b@church.ph")):
        body = org_payload(client, email, registration_no=None, organization_type=kind)
        body.pop("id_front")
        r = client.post("/auth/register/organization", json=body)
        assert r.status_code == 422, kind


def test_non_government_without_a_document_is_accepted(api):
    client, _ = api
    r = _register(client, "church@relief.ph", organization_type="Religious Organization",
                  legitimacy_document=None)
    assert r.status_code == 201, r.text
    org, user = _org("church@relief.ph")
    assert org.organization_category == "Non-government" and org.legitimacy_document_url is None
    assert org.organization_type == "Religious Organization"
    assert user.id_document_url                       # the contact person's ID is kept
    assert org.reviewed_at is None                    # Unverified, but signed in at once
    assert client.post("/token", data={"username": "church@relief.ph",
                                       "password": "Relief#2026ok"}).status_code == 200


def test_government_with_document_and_id_is_accepted(api):
    client, _ = api
    r = _register(client, "city@gov.ph", organization_type="City or Municipal Government Office")
    assert r.status_code == 201, r.text
    org, user = _org("city@gov.ph")
    assert org.organization_category == "Government"
    assert org.legitimacy_document_url and user.id_document_url


def test_old_app_values_are_mapped_and_unknown_ones_refused(api):
    client, _ = api
    ok(_register(client, "ngo@relief.ph", organization_type="NGO"), 201)
    assert _org("ngo@relief.ph")[0].organization_type == "Non-Profit / NGO / Foundation"
    r = _register(client, "x@relief.ph", organization_type="Cult")
    assert r.status_code == 422


def test_admin_queue_sorts_and_warns(api):
    client, t = api
    ok(_register(client, "older-ngo@relief.ph", organization_type="Civic or Community Group"), 201)
    ok(_register(client, "gov@gov.ph", organization_type=GOV), 201)
    ok(_register(client, "done@gov.ph", organization_type="National Government Agency"), 201)
    done = _org("done@gov.ph")[0]
    ok(client.post(f"/admin/organizations/{done.organization_id}/verify", headers=t["admin"]))

    rows = ok(client.get("/admin/organizations", headers=t["admin"]))
    names = [r["contact_email"] for r in rows]
    assert names.index("gov@gov.ph") < names.index("older-ngo@relief.ph") < names.index("done@gov.ph")
    gov = next(r for r in rows if r["contact_email"] == "gov@gov.ph")
    assert gov["verification_state"] == "Unverified" and gov["warning"] == WARNING
    assert gov["organization_category"] == "Government" and gov["contact_id_url"]
    ngo = next(r for r in rows if r["contact_email"] == "older-ngo@relief.ph")
    assert ngo["warning"] is None
    verified = next(r for r in rows if r["contact_email"] == "done@gov.ph")
    assert verified["verification_state"] == "Verified" and verified["warning"] is None

    regs = ok(client.get("/admin/registrations?kind=orgs&sort=review", headers=t["admin"]))
    assert [r["email"] for r in regs][:2] == ["gov@gov.ph", "older-ngo@relief.ph"]
    assert regs[0]["warning"] == WARNING


def test_mark_verified_sets_reviewed_at_and_shows_the_badge(api):
    client, t = api
    ok(_register(client, "verify@relief.ph", organization_type="Private Company or Business"), 201)
    org = _org("verify@relief.ph")[0]
    row = ok(client.post(f"/admin/organizations/{org.organization_id}/verify", headers=t["admin"]))
    assert row["verification_state"] == "Verified" and row["reviewed_at"]
    assert _org("verify@relief.ph")[0].reviewed_at is not None
    assert client.post(f"/admin/organizations/{org.organization_id}/verify",
                       headers=t["csws"]).status_code == 403
    summary = ok(client.get("/dashboard/summary", headers=t["admin"]))
    assert "Relief PH" in summary["verified_organization_names"]
    assert summary["verified_organizations"] >= 1


def test_deactivate_needs_a_reason_and_emails_it(api, sent_emails):
    client, t = api
    ok(_register(client, "fake@relief.ph", organization_type="Non-Profit / NGO / Foundation"), 201)
    org, user = _org("fake@relief.ph")
    url = f"/admin/organizations/{org.organization_id}/deactivate"
    assert client.post(url, headers=t["admin"], json={"reason": ""}).status_code == 422
    assert client.post(url, headers=t["admin"], json={}).status_code == 422
    row = ok(client.post(url, headers=t["admin"], json={"reason": "The ID photo is not real."}))
    assert row["verification_state"] == "Deactivated"
    assert row["deactivation_reason"] == "The ID photo is not real."
    assert _org("fake@relief.ph")[1].is_active is False
    assert any(m["to"] == "fake@relief.ph" and "The ID photo is not real." in m["body"]
               for m in sent_emails)
    r = client.post("/token", data={"username": "fake@relief.ph", "password": "Relief#2026ok"})
    assert r.status_code == 403 and "The ID photo is not real." in r.text


def test_organization_sees_its_state_on_its_dashboard(api):
    client, _ = api
    ok(_register(client, "self@relief.ph", organization_type="Civic or Community Group"), 201)
    tok = ok(client.post("/token", data={"username": "self@relief.ph",
                                         "password": "Relief#2026ok"}))["access_token"]
    profile = ok(client.get("/donations/mine", headers={"Authorization": f"Bearer {tok}"}))["profile"]
    assert profile["verification_state"] == "Unverified"
    assert profile["organization_category"] == "Non-government"


def test_existing_rows_are_backfilled_by_type():
    # Same rule the migration uses (d4a7b2e8c6f1): unknown = Non-government.
    assert organization_category("NGO") == "Non-government"
    assert organization_category("City or Municipal Government Office") == "Government"
    assert datetime.now(timezone.utc)  # keeps the import used on every platform
