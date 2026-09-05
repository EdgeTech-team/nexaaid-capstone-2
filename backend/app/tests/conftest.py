
"""
backend/app/tests/conftest.py
 
Shared fixtures for testing Module 3.4 (Report Management).
 
Uses an in-memory SQLite DB instead of your real Neon Postgres —
each test gets a clean schema, nothing touches production data, and
tests run fast with no network dependency. The one thing to watch:
SQLite is more permissive than Postgres about types, so a passing
test here doesn't 100% guarantee Postgres behaves identically for
edge cases (e.g. exact NUMERIC precision) — but for CRUD/status-flow
logic like this module, it's a faithful stand-in.
 
⚠️ ASSUMPTION: auth is mocked here via dependency_overrides on
`get_current_user` / `require_role`, since I still haven't seen the
real app.core.auth. Once that file is merged, these overrides may
need to match its actual dependency names/signatures — but the
*tests themselves* (what each endpoint should do) won't need to change.
"""
 
import pytest
from fastapi import Request
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker
from fastapi.testclient import TestClient
 
from main import app
from core.database import Base, get_db
from core.auth import get_current_user
from models.report import DisasterType, Barangay, Sitio, DisasterReport
from models.user_rbac_model import User
from models.role_model import Role
from models.organization_model import Organization
 
 
# ---------------------------------------------------------------------------
# Test database (fresh in-memory SQLite per test)
# ---------------------------------------------------------------------------
 
@pytest.fixture()
def db_session():
    engine = create_engine(
        "sqlite:///:memory:",
        connect_args={"check_same_thread": False},
    )
    Base.metadata.create_all(bind=engine)
    TestingSessionLocal = sessionmaker(bind=engine, autoflush=False, autocommit=False)
 
    session = TestingSessionLocal()
    try:
        yield session
    finally:
        session.close()
        Base.metadata.drop_all(bind=engine)
 
 
# ---------------------------------------------------------------------------
# Seed data every report test needs (FK targets: user, disaster type,
# barangay, sitio)
# ---------------------------------------------------------------------------
 
@pytest.fixture()
def seed(db_session):
    """
    Seeds everything the REAL User model requires, not just a bare
    user_id — user_rbac_model.User has NOT NULL first_name, last_name,
    contact_number, email, password_hash, role_id (FK -> roles), and
    organization_id (FK -> organizations). All of that has to exist
    before a User row can be inserted at all.
 
    Role names here ("Reporter", "Admin") are arbitrary test labels —
    they're NOT the same thing as the require_role("citizen"/"admin")
    strings used in api/v1/reports.py. Those two systems aren't wired
    together yet (see the open item about real RBAC role names).
    """
    org = Organization(organization_id=1, organization_name="Test Org")
    reporter_role = Role(role_id=1, role_name="Reporter")
    admin_role = Role(role_id=2, role_name="Admin")
    db_session.add_all([org, reporter_role, admin_role])
    db_session.flush()  # so role_id/organization_id exist for the FKs below
 
    reporter = User(
        user_id=1,
        first_name="Test",
        last_name="Reporter",
        contact_number="09170000001",
        email="reporter@test.local",
        password_hash="not-a-real-hash",
        role_id=reporter_role.role_id,
        organization_id=org.organization_id,
    )
    admin = User(
        user_id=2,
        first_name="Test",
        last_name="Admin",
        contact_number="09170000002",
        email="admin@test.local",
        password_hash="not-a-real-hash",
        role_id=admin_role.role_id,
        organization_id=org.organization_id,
    )
    dtype = DisasterType(disaster_type_id=1, name="Flood")
    barangay = Barangay(barangay_id=1, name="Barangay Test")
    sitio = Sitio(sitio_id=1, name="Sitio Test")
 
    db_session.add_all([reporter, admin, dtype, barangay, sitio])
    db_session.commit()
 
    return {
        "reporter_id": reporter.user_id,
        "admin_id": admin.user_id,
        "disaster_type_id": dtype.disaster_type_id,
        "barangay_id": barangay.barangay_id,
        "sitio_id": sitio.sitio_id,
    }
 
 
# ---------------------------------------------------------------------------
# Fake authenticated users
# ---------------------------------------------------------------------------
 
class FakeRole:
    """Mirrors the real Role model's shape enough for auth checks:
    core/auth.py does `user.role.role_name`, not a flat string."""
    def __init__(self, role_name: str):
        self.role_name = role_name
 
 
class FakeUser:
    def __init__(self, user_id: int, role_name: str):
        self.user_id = user_id
        self.role = FakeRole(role_name)
 
 
# ⚠️ IMPORTANT: app.dependency_overrides lives on the shared `app` object,
# not per-TestClient. If two client fixtures (e.g. admin_client and
# reporter_client) each did app.dependency_overrides[get_current_user] =
# <their own fixed user>, whichever fixture ran LAST would silently win
# for BOTH clients in any test that uses both together — a real bug that
# would've given false-positive test results. Instead: register fake
# users in a shared dict, and read WHICH one to return from a per-request
# header. The override itself is set once and never changes.
 
_fake_users_by_id: dict[int, FakeUser] = {}
 
 
def _get_current_user_override(request: Request):
    user_id = int(request.headers["X-Test-User-Id"])
    return _fake_users_by_id[user_id]
 
 
class AuthedTestClient(TestClient):
    """A TestClient that always identifies itself as one specific fake
    user, via a header the override above reads. Two instances of this
    can be used in the same test safely."""
 
    def __init__(self, *args, user_id: int, **kwargs):
        super().__init__(*args, **kwargs)
        self.headers.update({"X-Test-User-Id": str(user_id)})
 
 
def make_client(db_session, current_user: FakeUser) -> AuthedTestClient:
    _fake_users_by_id[current_user.user_id] = current_user
 
    def _get_db_override():
        try:
            yield db_session
        finally:
            pass  # db_session fixture owns closing/rollback
 
    app.dependency_overrides[get_db] = _get_db_override
    app.dependency_overrides[get_current_user] = _get_current_user_override
 
    return AuthedTestClient(app, user_id=current_user.user_id)
 
 
@pytest.fixture()
def reporter_client(db_session, seed):
    user = FakeUser(user_id=seed["reporter_id"], role_name="citizen")
    yield make_client(db_session, user)
    app.dependency_overrides.clear()
    _fake_users_by_id.clear()
 
 
@pytest.fixture()
def admin_client(db_session, seed):
    user = FakeUser(user_id=seed["admin_id"], role_name="admin")
    yield make_client(db_session, user)
    app.dependency_overrides.clear()
    _fake_users_by_id.clear()
 













