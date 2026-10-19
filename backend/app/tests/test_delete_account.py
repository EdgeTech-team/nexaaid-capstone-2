"""Appendix H 1.2 (testing feedback, Oct 2026): the Administrator can delete
a deactivated account, and the email can then be registered again.

Before this, deleting sample data left the users behind (their reports and
deliveries block a real DELETE), so registration kept answering
"Email already registered".
"""
from core import database
from models.audit_log_model import AuditLog
from models.upload_model import Upload, UploadBlob
from models.user_rbac_model import User
from tests.reg_helpers import STRONG_PASSWORD, donor_payload
from tests.test_role_flows import api, ok  # noqa: F401  (fixture)

EMAIL = "sample.donor@example.com"


def _register_and_login(client):
    ok(client.post("/auth/register/donor", json=donor_payload(client, EMAIL)), 201)
    tok = ok(client.post("/token", data={"username": EMAIL, "password": STRONG_PASSWORD}))
    return tok["user"]["user_id"] if "user" in tok else None, {"Authorization": f"Bearer {tok['access_token']}"}


def _uid(client, t, email):
    return next(u["user_id"] for u in ok(client.get("/admin/users", headers=t["admin"]))
                if u["email"] == email)


def test_delete_frees_the_email_and_hides_the_account(api):
    client, t = api
    _, old_token = _register_and_login(client)
    uid = _uid(client, t, EMAIL)

    # Must be deactivated first (deactivate is reversible, delete is not).
    r = client.delete(f"/admin/users/{uid}", headers=t["admin"])
    assert r.status_code == 409
    ok(client.patch(f"/admin/users/{uid}", headers=t["admin"], json={"is_active": False, "deactivation_reason": "Sample data"}))
    ok(client.delete(f"/admin/users/{uid}", headers=t["admin"]))

    # Gone from both sections and from the detail page.
    assert uid not in [u["user_id"] for u in ok(client.get("/admin/users", headers=t["admin"]))]
    assert client.get(f"/admin/users/{uid}", headers=t["admin"]).status_code == 404
    assert client.delete(f"/admin/users/{uid}", headers=t["admin"]).status_code == 404
    assert client.patch(f"/admin/users/{uid}", headers=t["admin"],
                        json={"is_active": True}).status_code == 404

    # The row stays (records point at it) but holds no personal data.
    db = database.SessionLocal()
    try:
        row = db.get(User, uid)
        assert row.deleted_at is not None and not row.is_active
        assert row.email.endswith("@deleted.nexaaid.invalid")
        assert (row.first_name, row.last_name) == ("Deleted", "User")
        assert row.username is None and row.address is None
        assert db.query(Upload).filter(Upload.owner_user_id == uid).count() == 0   # ID photos
        assert db.query(UploadBlob).count() == 0                                   # and their bytes
        log = db.query(AuditLog).filter(AuditLog.action == "DELETE ACCOUNT").one()
        assert log.entity_id == uid
    finally:
        db.close()

    # The same email registers again: the tester's bug.
    ok(client.post("/auth/register/donor", json=donor_payload(client, EMAIL)), 201)
    new_uid = _uid(client, t, EMAIL)
    assert new_uid != uid

    # The deleted account's old token must not open the new account.
    assert client.get("/health/secure", headers=old_token).status_code == 401


def test_delete_rules(api):
    client, t = api
    admin = _uid(client, t, "testadmin@gmail.com")
    csws = _uid(client, t, "csws.test@example.com")

    assert client.delete(f"/admin/users/{csws}", headers=t["csws"]).status_code == 403  # admin only
    assert client.delete("/admin/users/99999", headers=t["admin"]).status_code == 404
    assert client.delete(f"/admin/users/{admin}", headers=t["admin"]).status_code == 400  # self

    # Staff with records can still be deleted; their employee ID is freed too.
    ok(client.patch(f"/admin/users/{csws}", headers=t["admin"], json={"is_active": False, "deactivation_reason": "Sample data"}))
    ok(client.delete(f"/admin/users/{csws}", headers=t["admin"]))
    assert csws not in [u["user_id"] for u in ok(client.get("/admin/users", headers=t["admin"],
                                                             params={"active": "false"}))]


def test_cleanup_script_frees_sample_emails(api):
    """The database-cleanup task: sample accounts that already have records
    (so a SQL DELETE fails) are removed by the script, and the email works again."""
    from scripts import delete_accounts

    client, t = api
    ok(client.post("/auth/register/donor", json=donor_payload(client, EMAIL)), 201)
    # Blocked before the cleanup: the tester's bug.
    assert client.post("/auth/register/donor",
                       json=donor_payload(client, EMAIL)).status_code == 409

    db = database.SessionLocal()
    try:
        lines = []
        args = dict(emails=[EMAIL, "testadmin@gmail.com"], as_user="testadmin@gmail.com")
        assert delete_accounts.run(db, **args, out=lines.append) == 0          # dry run
        assert any(EMAIL in l for l in lines)
        assert any("Skipped testadmin@gmail.com" in l for l in lines)       # never the admin
        assert db.query(User).filter(User.email == EMAIL).count() == 1      # nothing written
        assert delete_accounts.run(db, **args, apply=True, ask=lambda _: "no",
                                   out=lines.append) == 1                  # must type APPLY
        assert delete_accounts.run(db, **args, apply=True, ask=lambda _: "APPLY",
                                   out=lines.append) == 0
        assert delete_accounts.run(db, out=lines.append) == 2               # no filter given
    finally:
        db.close()

    ok(client.post("/auth/register/donor", json=donor_payload(client, EMAIL)), 201)
    ok(client.get("/health/secure", headers=t["admin"]))                     # admin untouched
