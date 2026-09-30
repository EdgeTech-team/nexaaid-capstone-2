"""
backend/app/tests/test_role_flows.py

End-to-end check of every user role against the real auth stack:
real /token login, real require_role() (no auth overrides), and the
exact role names that exist in the live `roles` table.

Walks the whole relief chain the way the test app does:
  report -> admin validates -> donor/guest donate -> CSWS receives
  -> CMO / CSWS confirm -> CSWS delivery + logistics request
  -> DRRMO accepts / declines -> CSWS advances -> Barangay confirms receipt
and checks each role is blocked from what it shouldn't reach.
"""

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

from main import app
import core.database as database
from core.database import Base
from core.auth import hash_password
from models.role_model import Role
from models.user_rbac_model import User
from models.city_model import City
from models.barangay_model import Barangay
from models.sitio_model import Sitio
from models.disaster_type_model import DisasterType
from models.item_model import Item

PASSWORD = "testpass123"

# Same names and ids as the live Neon `roles` table.
ROLES = {
    1: "Administrator",
    2: "Individual Donor",
    3: "Relief Organization",
    4: "CMO Representative",
    5: "CSWS Main Office",
    6: "CSWS Disaster Unit",
    7: "Barangay Receiving Representative",
    8: "DRRMO Logistics Support",
}

ACCOUNTS = {
    "admin": ("testadmin@gmail.com", 1),
    "donor": ("donor.test@example.com", 2),
    "cmo": ("cmo.test@example.com", 4),
    "csws": ("csws.test@example.com", 5),
    "unit": ("rico.test@example.com", 6),
    "brgy": ("ana.test@example.com", 7),
    "drrmo": ("drrmo.test@example.com", 8),
}


@pytest.fixture()
def api():
    engine = create_engine(
        "sqlite:///:memory:",
        connect_args={"check_same_thread": False},
        poolclass=StaticPool,
    )
    Base.metadata.create_all(bind=engine)
    Session = sessionmaker(bind=engine, autoflush=False, autocommit=False)

    db = Session()
    db.add_all([Role(role_id=i, role_name=n) for i, n in ROLES.items()])
    db.add_all([
        City(city_id=1, city_name="Test City"),
        DisasterType(disaster_type_id=1, type_name="Flood"),
        Item(item_id=1, item_name="Rice", category="Food", unit_of_measure="kg"),
    ])
    db.flush()
    db.add(Barangay(barangay_id=1, barangay_name="Barangay Test", city_id=1))
    db.flush()
    db.add(Sitio(sitio_id=1, barangay_id=1, sitio_name="Sitio Test"))
    pw = hash_password(PASSWORD)
    for key, (email, role_id) in ACCOUNTS.items():
        db.add(User(
            first_name=key, last_name="Test", contact_number="09170000000",
            email=email, password_hash=pw, role_id=role_id,
            assigned_barangay_id=1 if key == "brgy" else None,
        ))
    db.commit()
    db.close()

    # Point the real get_db at the test DB (no override), so its
    # commit/rollback behaviour is exercised too.
    real_session_local = database.SessionLocal
    database.SessionLocal = Session
    app.dependency_overrides.clear()
    client = TestClient(app)

    tokens = {}
    for key, (email, _) in ACCOUNTS.items():
        r = client.post("/token", data={"username": email, "password": PASSWORD})
        assert r.status_code == 200, (key, r.text)
        tokens[key] = {"Authorization": f"Bearer {r.json()['access_token']}"}

    yield client, tokens
    database.SessionLocal = real_session_local
    Base.metadata.drop_all(bind=engine)


def ok(r, code=200):
    assert r.status_code == code, f"{r.request.method} {r.request.url.path} -> {r.status_code}: {r.text}"
    return r.json() if r.content else None


def test_login_reports_real_role_name(api):
    client, t = api
    for key, (_, role_id) in ACCOUNTS.items():
        me = ok(client.get("/health/secure", headers=t[key]))
        assert me["role"] == ROLES[role_id]


def test_full_relief_chain_across_all_roles(api):
    client, t = api

    # --- 3.3 donor self-registration + login -----------------------------
    ok(client.post("/auth/register/donor", json={
        "first_name": "New", "last_name": "Donor", "email": "new.donor@example.com",
        "password": PASSWORD, "contact_number": "09171234567",
    }), 201)
    ok(client.post("/token", data={"username": "new.donor@example.com", "password": PASSWORD}))

    # --- 3.3 admin creates an internal account ---------------------------
    ok(client.post("/admin/users", headers=t["admin"], json={
        "first_name": "New", "last_name": "Staff", "email": "new.staff@example.com",
        "password": PASSWORD, "contact_number": "09171234567",
        "role_name": "CSWS Main Office",
    }), 201)
    assert client.post("/admin/users", headers=t["csws"], json={}).status_code in (403, 422)

    # --- 3.4 CSWS Disaster Unit files a report (UC-CD1), admin validates (UC-A3)
    report = ok(client.post("/reports/", headers=t["unit"], json={
        "disaster_type_id": 1, "barangay_id": 1, "sitio_id": 1,
        "description": "Flooding", "affected_families": 40,
        "assistance_needed": "Rice", "estimated_quantity": 100,
    }), 201)
    rid = report["report_id"]
    assert report["source"] == "Web"   # stored exactly as the live DB constraint expects
    mobile = ok(client.post("/reports/", headers=t["unit"], json={
        "disaster_type_id": 1, "barangay_id": 1, "source": "mobile"}), 201)
    assert mobile["source"] == "Mobile"

    # dropdown data (public, used by the app instead of typed ids)
    lk = ok(client.get("/lookups"))
    assert lk["disaster_types"] == [{"id": 1, "name": "Flood"}]
    assert lk["items"][0]["name"] == "Rice (kg)"
    assert {r["id"] for r in lk["reports"]} == {rid, mobile["report_id"]}
    assert lk["validated_reports"] == []          # nothing validated yet
    ok(client.get(f"/reports/{rid}", headers=t["csws"]))   # staff can view any report
    ok(client.get(f"/reports/{rid}", headers=t["unit"]))
    assert client.post(f"/reports/{rid}/validate", headers=t["csws"], json={}).status_code == 403
    validated = ok(client.post(f"/reports/{rid}/validate", headers=t["admin"], json={}))
    assert validated["status"] == "Validated"
    assert validated["priority_level"]                      # 3.11 scoring ran
    assert [r["id"] for r in ok(client.get("/lookups"))["validated_reports"]] == [rid]

    # --- 3.7 needs monitoring: CSWS (both units), admin, barangay --------
    for who in ("admin", "csws", "unit", "brgy"):
        rows = ok(client.get("/reports/monitoring", headers=t[who]))
        row = next(r for r in rows if r["report_id"] == rid)
        assert row["total_items_needed"] == 100
    assert client.get("/reports/", headers=t["donor"]).status_code == 403

    # --- 3.5 donations: logged-in donor and guest ------------------------
    base = {"report_id": rid, "item_id": 1, "packaging": "Box", "handover_method": "Drop Off"}
    d1 = ok(client.post("/donations/", headers=t["donor"], json={**base, "quantity": 60}))
    d2 = ok(client.post("/donations/", json={**base, "quantity": 5,
             "guest_donor": {"full_name": "Guest", "contact_number": "0917"}}))
    assert d1["status"] == d2["status"] == "Pending"
    assert ok(client.get(f"/donations/{d1['donation_id']}/qr"))["qr_image_base64"]

    # --- 3.6 CSWS receives, inventory updates ----------------------------
    assert client.get("/donations/pending", headers=t["brgy"]).status_code == 403
    pending = ok(client.get("/donations/pending", headers=t["csws"]))
    assert {d["donation_id"] for d in pending} == {d1["donation_id"], d2["donation_id"]}
    for d, qty in ((d1, 60), (d2, 5)):
        ok(client.post("/donations/receive", headers=t["csws"],
                       json={"donation_id": d["donation_id"], "actual_quantity": qty}))
    assert ok(client.get("/lookups"))["pending_donations"] == []
    assert len(ok(client.get("/lookups"))["received_donations"]) == 2
    inv = ok(client.get("/donations/inventory", headers=t["csws"]))
    assert inv[0]["quantity"] == 65

    # --- 3.8 CMO confirms one donation, CSWS confirms the other ----------
    assert client.get("/cmo/donations/pending", headers=t["csws"]).status_code == 403
    assert len(ok(client.get("/cmo/donations/pending", headers=t["cmo"]))) == 2
    conf = ok(client.post(f"/cmo/donations/{d1['donation_id']}/confirm", headers=t["cmo"],
                          json={"status": "Confirmed", "notes": "ok"}), 201)
    assert conf["status"] == "Confirmed"
    ok(client.post(f"/donations/{d2['donation_id']}/confirm", headers=t["csws"]))
    assert ok(client.get("/cmo/dashboard", headers=t["cmo"])) == {"pending_confirmation": 0, "confirmed": 2}

    # --- 3.10 CSWS creates a delivery ------------------------------------
    delivery = ok(client.post("/deliveries/", headers=t["csws"], json={
        "report_id": rid, "destination_barangay_id": 1,
        "delivery_date": "2026-10-01T08:00:00", "items": [{"item_id": 1, "quantity": 50}],
    }), 201)
    did = delivery["delivery_id"]
    assert ok(client.get(f"/deliveries/{did}", headers=t["brgy"]))["status"] == "Preparing"

    # --- 3.9 logistics request for that delivery (UC-CM2 3a / UC-DR1) ----
    req = {"delivery_id": did, "notes": "Need a truck"}
    lr1 = ok(client.post("/logistics/requests", headers=t["csws"], json=req), 201)
    assert lr1["delivery_id"] == did                          # no new empty delivery
    assert client.post("/logistics/requests", headers=t["csws"], json=req).status_code == 409
    assert client.get("/drrmo/requests", headers=t["csws"]).status_code == 403
    assert len(ok(client.get("/drrmo/requests", headers=t["drrmo"]))) == 1
    dec = ok(client.patch(f"/drrmo/requests/{lr1['request_id']}/decline", headers=t["drrmo"],
                          json={"notes": "No truck available"}))
    assert dec["status"] == "Declined"
    lr2 = ok(client.post("/logistics/requests", headers=t["csws"], json=req), 201)  # ask again
    acc = ok(client.patch(f"/drrmo/requests/{lr2['request_id']}/accept", headers=t["drrmo"],
                          json={"scheduled_date": "2026-10-02T08:00:00"}))
    assert acc["status"] == "Accepted"
    assert ok(client.get("/drrmo/dashboard", headers=t["drrmo"]))["scheduled"] == 1

    # --- 3.10 CSWS advances, Barangay confirms receipt -------------------
    assert client.post(f"/deliveries/{did}/advance", headers=t["brgy"]).status_code == 403
    assert ok(client.post(f"/deliveries/{did}/advance", headers=t["csws"]))["status"] == "In Transit"
    assert ok(client.post(f"/deliveries/{did}/advance", headers=t["csws"]))["status"] == "Delivered"
    assert client.post(f"/deliveries/{did}/confirm-receipt", headers=t["csws"], json={}).status_code == 403
    receipt = ok(client.post(f"/deliveries/{did}/confirm-receipt", headers=t["brgy"],
                             json={"remarks": "Received complete"}), 201)
    assert receipt["delivery"]["status"] == "Confirmed"
    assert receipt["fulfillment"]["fulfillment_percentage"] == "50.00"
    assert receipt["fulfillment"]["verification_status"] == "Partial"

    # --- 3.12 dashboards --------------------------------------------------
    for who in ("admin", "csws", "unit", "brgy"):
        for path in ("summary", "reports-breakdown", "fulfillment", "logistics"):
            ok(client.get(f"/dashboard/{path}", headers=t[who]))
        assert client.get("/dashboard/summary", headers=t["donor"]).status_code == 403
    summary = ok(client.get("/dashboard/summary", headers=t["admin"]))
    assert summary["total_donations"] == 2
    assert summary["total_deliveries"] == 1
    assert summary["total_logistics_requests"] == 2
