"""
Registration with uploaded files and the Administrator's review
(adviser items 2 and 2.1).

UC-D1 Register Individual Donor: step 3 valid ID (front and back), alt 6a,
      active right away (steps 6-7).
UC-A2 Review Organization Registration: step 4 details + supporting
      document, alt 4a missing/unreadable document, 6a reject/hold.
UC-A1: the Administrator sees a donor's ID and can deactivate the account.
"""
import core.database as database
from core.storage import get_storage
from models.audit_log_model import AuditLog
from models.organization_model import Organization
from models.upload_model import Upload
from models.user_rbac_model import User
from tests.reg_helpers import (
    STRONG_PASSWORD, donor_payload, org_payload, pdf, png, ref, upload,
)
from tests.test_role_flows import api, ok  # noqa: F401  (fixture)


def _db():
    return database.SessionLocal()


def _user(email):
    db = _db()
    try:
        return db.query(User).filter(User.email == email).first()
    finally:
        db.close()


def _detail(r):
    return str(r.json()["detail"])


# ---------------------------------------------------------------- donor (UC-D1)

def test_donor_registers_with_id_front_and_back(api):
    client, t = api
    body = donor_payload(client, "Maria.Cruz@Example.com",
                         first_name="  maria   clara ", last_name="dela cruz",
                         contact_number="+63 917 123 4567", id_type="Driver's License")
    created = ok(client.post("/auth/register/donor", json=body), 201)
    assert created["is_active"] is True                    # steps 6-7: no approval needed

    db = _db()
    try:
        u = db.query(User).filter(User.email == "maria.cruz@example.com").one()
        assert (u.first_name, u.last_name) == ("Maria Clara", "Dela Cruz")
        assert u.contact_number == "09171234567"           # +63 accepted, stored as 09...
        assert u.id_type == "Driver's License"
        assert u.id_document_url == f"/uploads/{body['id_front']['file_id']}"
        owned = {up.purpose: up for up in db.query(Upload).filter(Upload.owner_user_id == u.user_id)}
        assert set(owned) == {"id_front", "id_back"}       # back found via uploads table
        assert all(up.claim_token_hash is None for up in owned.values())
        log = db.query(AuditLog).filter(AuditLog.action == "REGISTER DONOR").one()
        assert log.user_id == u.user_id and log.new_value["consent_ra10173"] is True
    finally:
        db.close()

    # The new donor can log in and see their own ID; another donor cannot.
    r = ok(client.post("/token", data={"username": "maria.cruz@example.com", "password": STRONG_PASSWORD}))
    me = {"Authorization": f"Bearer {r['access_token']}"}
    assert client.get(created_url := f"/uploads/{body['id_back']['file_id']}", headers=me).status_code == 200
    assert client.get(created_url, headers=t["donor"]).status_code == 404
    assert client.get(created_url).status_code == 404


def test_donor_registers_without_id_type(api):
    """D1: the app no longer asks for the ID type. The field is optional."""
    client, t = api
    body = donor_payload(client, "noidtype@example.com")
    assert "id_type" not in body
    ok(client.post("/auth/register/donor", json=body), 201)
    u = _user("noidtype@example.com")
    assert u is not None and u.id_type is None


def test_donor_registration_requires_both_sides_consent_and_rules(api):
    client, t = api
    base = donor_payload(client, "rules@example.com")
    cases = {
        "id_back": None,                                   # back missing
        "consent": False,                                  # RA 10173 consent
        "accepted_terms": False,                           # D3: Terms and Conditions
        "contact_number": "0917123456",                    # 10 digits
        "id_type": "Barangay Clearance",                   # not in the list
        "first_name": "J0hn",                              # digits in a name
        "confirm_password": "Different#2026",
        "password": "onlyletters",                         # D2: no number
    }
    for field, value in cases.items():
        body = dict(base)
        if value is None:
            body.pop(field)
        else:
            body[field] = value
            if field == "password":
                body["confirm_password"] = value
        r = client.post("/auth/register/donor", json=body)
        assert r.status_code == 422, (field, r.text)

    same = dict(base, id_back=base["id_front"])            # one photo sent as both sides
    r = client.post("/auth/register/donor", json=same)
    assert r.status_code == 422 and "separate" in _detail(r)
    assert _user("rules@example.com") is None


def test_donor_terms_are_required(api):
    """D3: no account without the Terms and Conditions checkbox."""
    client, t = api
    base = donor_payload(client, "terms@example.com")

    missing = dict(base)
    missing.pop("accepted_terms")
    assert client.post("/auth/register/donor", json=missing).status_code == 422

    refused = dict(base, accepted_terms=False)
    r = client.post("/auth/register/donor", json=refused)
    assert r.status_code == 422 and "Terms" in r.text
    assert _user("terms@example.com") is None

    # With the box ticked the same request works.
    ok(client.post("/auth/register/donor", json=base), 201)
    assert _user("terms@example.com") is not None


def test_relaxed_password_rule(api):
    """D2: 8-64 characters with at least one letter and one number."""
    client, t = api
    base = donor_payload(client, "pw@example.com")

    for weak in ("abcdefgh", "12345678", "short1"):
        body = dict(base, password=weak, confirm_password=weak)
        r = client.post("/auth/register/donor", json=body)
        assert r.status_code == 422, weak

    easy = "Abc12345"                                      # capital letter, no symbol: allowed
    body = dict(base, password=easy, confirm_password=easy)
    ok(client.post("/auth/register/donor", json=body), 201)
    ok(client.post("/token", data={"username": "pw@example.com", "password": easy}))


def test_failed_claim_creates_nothing(api):
    client, t = api
    body = donor_payload(client, "rollback@example.com")

    # Wrong token on the back -> 400, and no user is left behind.
    bad = dict(body, id_back={"file_id": body["id_back"]["file_id"], "claim_token": "guess"})
    r = client.post("/auth/register/donor", json=bad)
    assert r.status_code == 400 and "upload it again" in _detail(r)
    assert _user("rollback@example.com") is None
    db = _db()
    try:
        front = db.query(Upload).filter(Upload.file_id == body["id_front"]["file_id"]).one()
        assert front.owner_user_id is None                 # the front claim was rolled back too
    finally:
        db.close()

    # A back photo sent as the front (wrong purpose) -> 400.
    swapped = dict(body, id_front=body["id_back"], id_back=body["id_front"])
    assert client.post("/auth/register/donor", json=swapped).status_code == 400
    assert _user("rollback@example.com") is None

    # The original, untouched request still works afterwards.
    ok(client.post("/auth/register/donor", json=body), 201)
    # Tokens are single use: replaying the same files for another email fails.
    replay = dict(body, email="replay@example.com")
    assert client.post("/auth/register/donor", json=replay).status_code == 400
    assert _user("replay@example.com") is None


def test_duplicate_email_is_rejected_case_insensitively(api):
    client, t = api
    ok(client.post("/auth/register/donor", json=donor_payload(client, "dup@example.com")), 201)
    r = client.post("/auth/register/donor", json=donor_payload(client, "DUP@example.com"))
    assert r.status_code == 409


# ---------------------------------------------------------- organization (UC-A2)

def test_organization_registers_with_document_and_split_contact(api):
    client, t = api
    body = org_payload(client, "ops@relief.ph", organization_type="Other",
                       organization_type_other="Cooperative")
    org = ok(client.post("/auth/register/organization", json=body), 201)
    assert org["status"] == "Approved"

    db = _db()
    try:
        o = db.get(Organization, org["organization_id"])
        u = db.query(User).filter(User.email == "ops@relief.ph").one()
        assert o.contact_person == "Jo Santos"
        assert (u.first_name, u.last_name) == ("Jo", "Santos")   # no more last_name=""
        assert o.organization_type == "Other: Cooperative"
        assert o.legitimacy_document_url == f"/uploads/{body['legitimacy_document']['file_id']}"
        up = db.query(Upload).filter(Upload.file_id == body["legitimacy_document"]["file_id"]).one()
        assert up.owner_user_id == u.user_id
    finally:
        db.close()

    # Registration is active immediately; admin review is tracked separately.
    r = client.post("/token", data={"username": "ops@relief.ph", "password": STRONG_PASSWORD})
    assert r.status_code == 200
    rows = ok(client.get("/admin/organizations?reviewed=false", headers=t["admin"]))
    row = next(o for o in rows if o["organization_id"] == org["organization_id"])
    assert row["reviewed_at"] is None


def test_organization_document_and_type_are_required(api):
    client, t = api
    body = org_payload(client, "nodoc@relief.ph")
    for field, value in {"organization_type": "Cult",
                         "consent": False, "contact_last_name": ""}.items():
        b = dict(body)
        if value is None:
            b.pop(field)
        else:
            b[field] = value
        assert client.post("/auth/register/organization", json=b).status_code == 422, field
    other = dict(body, organization_type="Other")          # "Other" needs the specify field
    assert client.post("/auth/register/organization", json=other).status_code == 422

    # An ID photo can't be used as a legitimacy document.
    wrong = dict(body, legitimacy_document=ref(upload(client, "id_front")))
    assert client.post("/auth/register/organization", json=wrong).status_code == 400
    db = _db()
    try:
        assert db.query(Organization).filter(Organization.contact_email == "nodoc@relief.ph").count() == 0
    finally:
        db.close()


def test_organization_terms_are_required(api):
    """D3: organizations must also accept the Terms and Conditions."""
    client, t = api
    body = org_payload(client, "orgterms@relief.ph")

    missing = dict(body)
    missing.pop("accepted_terms")
    assert client.post("/auth/register/organization", json=missing).status_code == 422

    refused = dict(body, accepted_terms=False)
    r = client.post("/auth/register/organization", json=refused)
    assert r.status_code == 422 and "Terms" in r.text
    assert _user("orgterms@relief.ph") is None


# ------------------------------------------------------ Administrator review

def test_admin_sees_donor_detail_and_documents(api):
    client, t = api
    body = donor_payload(client, "idcheck@example.com", id_type="Passport")
    created = ok(client.post("/auth/register/donor", json=body), 201)
    uid = created["user_id"]

    detail = ok(client.get(f"/admin/users/{uid}", headers=t["admin"]))
    assert detail["id_type"] == "Passport" and detail["role"] == "Individual Donor"
    docs = ok(client.get(f"/admin/users/{uid}/documents", headers=t["admin"]))
    assert {d["purpose"] for d in docs} == {"id_front", "id_back"}
    for d in docs:
        assert set(d) == {"file_id", "purpose", "url", "content_type", "created_at"}
        assert client.get(d["url"], headers=t["admin"]).status_code == 200

    # Only the Administrator; unknown accounts are 404 (UC-A1 alt 3a).
    for key in ("donor", "csws", "brgy"):
        assert client.get(f"/admin/users/{uid}/documents", headers=t[key]).status_code == 403
        assert client.get(f"/admin/users/{uid}", headers=t[key]).status_code == 403
    assert client.get("/admin/users/99999", headers=t["admin"]).status_code == 404
    assert client.get("/admin/users/99999/documents", headers=t["admin"]).status_code == 404

    # Invalid ID -> the Administrator deactivates the account (UC-A1 step 5).
    ok(client.patch(f"/admin/users/{uid}", headers=t["admin"], json={"is_active": False, "deactivation_reason": "Test reason"}))
    r = client.post("/token", data={"username": "idcheck@example.com", "password": STRONG_PASSWORD})
    assert r.status_code == 403


def test_organization_document_status_flags(api):
    client, t = api
    org = ok(client.post("/auth/register/organization", json=org_payload(client, "doc@relief.ph")), 201)
    oid = org["organization_id"]
    d = ok(client.get(f"/admin/organizations/{oid}/document", headers=t["admin"]))
    assert d["status"] == "ok" and d["content_type"] == "application/pdf"
    assert client.get(f"/admin/organizations/{oid}/document", headers=t["csws"]).status_code == 403
    assert client.get("/admin/organizations/99999/document", headers=t["admin"]).status_code == 404

    db = _db()
    try:
        # Old rows from before uploads: no document, or a typed-in link (alt 4a).
        old = Organization(org_name="Old Org", organization_type="NGO", address="Old address here",
                           contact_person="Old Contact", registration_no="OLD-1",
                           contact_email="old@org.ph")
        link = Organization(org_name="Link Org", organization_type="NGO", address="Old address here",
                            contact_person="Old Contact", registration_no="OLD-2",
                            contact_email="link@org.ph", legitimacy_document_url="https://drive.example/doc")
        db.add_all([old, link])
        db.commit()
        old_id, link_id = old.organization_id, link.organization_id
        # The uploaded file disappears from storage -> unreadable.
        up = db.query(Upload).filter(Upload.file_id == d["file_id"]).one()
        get_storage().delete(up.storage_key)
    finally:
        db.close()

    assert ok(client.get(f"/admin/organizations/{old_id}/document", headers=t["admin"]))["status"] == "missing"
    assert ok(client.get(f"/admin/organizations/{link_id}/document", headers=t["admin"]))["status"] == "external"
    assert ok(client.get(f"/admin/organizations/{oid}/document", headers=t["admin"]))["status"] == "unreadable"
    rows = {o["organization_id"]: o for o in ok(client.get("/admin/organizations", headers=t["admin"]))}
    assert rows[old_id]["document_missing"] is True       # existing flag kept for old rows


def test_unreadable_image_upload_asks_for_reupload(api):
    """UC-D1 alt 6a: a broken photo is refused at upload with a re-upload message."""
    client, t = api
    broken = png()[:40]
    r = client.post("/uploads", data={"purpose": "id_front"},
                    files={"file": ("id.png", broken, "image/png")})
    assert r.status_code == 400 and "again" in _detail(r)
    assert client.post("/uploads", data={"purpose": "id_back"},
                       files={"file": ("id.pdf", pdf(), "application/pdf")}).status_code == 201


def test_organization_document_is_optional(api):
    client, t = api
    body = org_payload(client, "optdoc@relief.ph")
    body.pop("legitimacy_document", None)
    assert client.post("/auth/register/organization", json=body).status_code == 201