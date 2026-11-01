"""
F-06: two requests at the same moment cannot oversell stock or receive the
same donation twice. Needs a REAL Postgres (SQLite cannot run two
transactions at once and ignores FOR UPDATE), so it runs only when
TEST_POSTGRES_URL points at a throwaway local Postgres, e.g. Docker:
    TEST_POSTGRES_URL=postgresql://postgres:postgres@localhost:5433/postgres
Otherwise it is skipped. It refuses any Neon URL.
"""
import os
import secrets
import threading
from datetime import datetime, timezone

import pytest
from fastapi import HTTPException
from fastapi.testclient import TestClient
from sqlalchemy import create_engine
from sqlalchemy.engine import make_url
from sqlalchemy.orm import sessionmaker

import core.database as database
from core.auth import hash_password
from core.database import Base
from main import app
from models.barangay_model import Barangay
from models.city_model import City
from models.delivery import Delivery
from models.disaster_type_model import DisasterType
from models.item_model import Item
from models.physical_donation_model import PhysicalDonation
from models.received_goods_model import ReceivedGoods
from models.role_model import Role
from models.sitio_model import Sitio
from models.user_rbac_model import User
from tests.test_role_flows import ACCOUNTS, PASSWORD, ROLES, ok

TEST_URL = os.getenv("TEST_POSTGRES_URL")
pytestmark = pytest.mark.skipif(not TEST_URL, reason="Set TEST_POSTGRES_URL to a throwaway local Postgres")


def _seed(Session):
    """The same rows as the `api` fixture of tests/test_role_flows.py."""
    db = Session()
    db.add_all([Role(role_id=i, role_name=n) for i, n in ROLES.items()])
    db.add_all([City(city_id=1, city_name="Test City"),
                DisasterType(disaster_type_id=1, type_name="Flood"),
                Item(item_id=1, item_name="Rice", category="Food", unit_of_measure="kg")])
    db.flush()
    db.add(Barangay(barangay_id=1, barangay_name="Barangay Test", city_id=1))
    db.add(Barangay(barangay_id=2, barangay_name="Barangay Two", city_id=1))
    db.flush()
    db.add(Sitio(sitio_id=1, barangay_id=1, sitio_name="Sitio Test"))
    pw = hash_password(PASSWORD)
    for key, (email, role_id) in ACCOUNTS.items():
        db.add(User(first_name=key, last_name="Test", contact_number="09170000000", email=email,
                    password_hash=pw, role_id=role_id,
                    assigned_barangay_id={"brgy": 1, "brgy2": 2}.get(key)))
    db.commit()
    db.close()


@pytest.fixture()
def pg():
    if "neon.tech" in TEST_URL.lower():
        pytest.fail("TEST_POSTGRES_URL points at Neon. Use a throwaway local Postgres.")
    server = create_engine(TEST_URL, isolation_level="AUTOCOMMIT")
    name = f"nexaaid_racetest_{secrets.token_hex(4)}"
    with server.connect() as conn:
        conn.exec_driver_sql(f'CREATE DATABASE "{name}"')
    engine = create_engine(make_url(TEST_URL).set(database=name))
    Session = sessionmaker(bind=engine, autoflush=False, autocommit=False)
    real_session_local = database.SessionLocal
    try:
        Base.metadata.create_all(bind=engine)
        _seed(Session)
        database.SessionLocal = Session
        app.dependency_overrides.clear()
        client = TestClient(app)
        tokens = {}
        for key, (email, _) in ACCOUNTS.items():
            r = ok(client.post("/token", data={"username": email, "password": PASSWORD}))
            tokens[key] = {"Authorization": f"Bearer {r['access_token']}"}
        yield client, tokens, Session
    finally:
        database.SessionLocal = real_session_local
        engine.dispose()
        with server.connect() as conn:
            conn.exec_driver_sql(f'DROP DATABASE IF EXISTS "{name}" WITH (FORCE)')
        server.dispose()


def _report(client, t):
    rid = ok(client.post("/reports/", headers=t["unit"], json={
        "disaster_type_id": 1, "barangay_id": 1, "estimated_quantity": 100}), 201)["report_id"]
    ok(client.post(f"/reports/{rid}/validate", headers=t["admin"], json={}))
    return rid


def _donate(client, t, rid, qty):
    return ok(client.post("/donations/", headers=t["donor"], json={
        "report_id": rid, "item_id": 1, "packaging": "Sack",
        "handover_method": "Drop Off", "quantity": qty}))["donation_id"]


def _in_thread(fn):
    """Run fn in a thread; returns (thread, result dict with 'status')."""
    result = {}

    def run():
        try:
            fn()
            result["status"] = "ok"
        except HTTPException as e:
            result["status"] = e.status_code

    th = threading.Thread(target=run)
    th.start()
    return th, result


def _csws(session):
    return session.query(User).filter(User.email == ACCOUNTS["csws"][0]).one()


def test_two_deliveries_at_once_cannot_oversell(pg):
    from api.v1.deliveries import create_delivery
    from schemas.delivery import DeliveryCreate
    client, t, Session = pg
    rid = _report(client, t)
    did = _donate(client, t, rid, 100)
    ok(client.post("/donations/receive", headers=t["csws"],
                   json={"donation_id": did, "actual_quantity": 100}))     # 100 kg in stock
    payload = DeliveryCreate(report_id=rid, destination_barangay_id=1,
                             delivery_date=datetime.now(timezone.utc),
                             items=[{"item_id": 1, "quantity": 60}])
    a, b = Session(), Session()
    try:
        create_delivery(payload, db=a, current_user=_csws(a))   # A holds the stock row, not committed

        def second():
            try:
                create_delivery(payload, db=b, current_user=_csws(b))
                b.commit()
            except HTTPException:
                b.rollback()
                raise

        th, result = _in_thread(second)
        th.join(timeout=1.0)
        assert th.is_alive()                 # B really overlaps A: it waits for A
        a.commit()
        th.join(timeout=15)
        assert result["status"] == 409       # "Not enough stock": only 40 kg left
    finally:
        a.close()
        b.close()
    db = Session()
    try:
        assert db.query(Delivery).filter(Delivery.report_id == rid).count() == 1
    finally:
        db.close()
    assert ok(client.get(f"/donations/inventory?report_id={rid}", headers=t["csws"]))[0]["quantity"] == 40


def test_the_same_donation_cannot_be_received_twice(pg):
    from api.v1.receiving_routes import receive_donation
    from schemas.received_goods_schema import ReceivedGoodsCreate
    client, t, Session = pg
    rid = _report(client, t)
    did = _donate(client, t, rid, 10)
    payload = ReceivedGoodsCreate(donation_id=did, actual_quantity=10)
    a, b = Session(), Session()
    try:
        # A starts receiving: it holds the donation row (as receive_donation does).
        a.query(PhysicalDonation).filter(PhysicalDonation.donation_id == did).with_for_update().one()

        def second():
            try:
                receive_donation(payload, db=b, current_user=_csws(b))
            except HTTPException:
                b.rollback()
                raise

        th, result = _in_thread(second)
        th.join(timeout=1.0)
        assert th.is_alive()                 # the second scan waits for the first
        receive_donation(payload, db=a, current_user=_csws(a))   # commits, releases the lock
        th.join(timeout=15)
        assert result["status"] == 400       # "already 'Received', cannot receive again"
    finally:
        a.close()
        b.close()
    db = Session()
    try:
        assert db.query(ReceivedGoods).filter(ReceivedGoods.donation_id == did).count() == 1
    finally:
        db.close()
    assert ok(client.get(f"/donations/inventory?report_id={rid}", headers=t["csws"]))[0]["quantity"] == 10
